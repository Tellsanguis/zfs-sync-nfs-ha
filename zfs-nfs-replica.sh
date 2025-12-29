#!/bin/bash
#
# Script de réplication ZFS automatique pour NFS HA (Multi-pools)
# À déployer sur tous les nœuds de production du cluster Proxmox
#
# Ce script version 2.1 :
# - Supporte la réplication de plusieurs pools ZFS simultanément
# - Vérifie 3 fois que le LXC nfs-server est actif localement
# - Vérifie l'état de santé des disques et pools ZFS avant réplication
# - Détecte les disques manquants, pools dégradés, erreurs I/O
# - Migration automatique du LXC en cas de défaillance matérielle
# - Protection anti-ping-pong (arrêt du LXC si erreur < 1h)
# - Détermine le nœud distant automatiquement
# - Réplique chaque pool ZFS vers le nœud passif avec isolation des erreurs
# - Utilise un verrou par pool pour éviter les réplications concurrentes
# - Gère l'activation/désactivation de Sanoid selon le nœud actif
# - Logs avec rotation automatique (2 semaines de rétention)
# - Fichiers d'état séparés par pool (tailles, UUIDs disques, erreurs critiques)
#
# Auteur : BENE Maël
# Version : 2.1.0
#

set -euo pipefail

# Configuration
SCRIPT_VERSION="2.2.0"
REPO_URL="https://forgejo.tellserv.fr/Tellsanguis/zfs-sync-nfs-ha"
SCRIPT_URL="${REPO_URL}/raw/branch/main/zfs-nfs-replica.sh"
SCRIPT_PATH="${BASH_SOURCE[0]}"
AUTO_UPDATE_ENABLED=true  # Mettre à false pour désactiver l'auto-update

# Configuration du container LXC
CTID=103
CONTAINER_NAME="nfs-server"

# Support multi-pools - Liste des pools à répliquer
# Ajouter ou retirer des pools selon vos besoins
ZPOOLS=("zpool1" "zpool2")

# Configuration des nœuds du cluster
# Format: NODE_NAME:IP_ADDRESS
# Ajouter tous les nœuds de production du cluster
declare -A CLUSTER_NODES=(
    ["acemagician"]="192.168.100.10"
    ["elitedesk"]="192.168.100.20"
)

CHECK_DELAY=2  # Délai entre chaque vérification (secondes)
LOG_FACILITY="local0"
SSH_KEY="/root/.ssh/id_ed25519_zfs_replication"
STATE_DIR="/var/lib/zfs-nfs-replica"
SIZE_TOLERANCE=20  # Tolérance de variation en pourcentage (±20%)
MIN_REMOTE_RATIO=50  # Le distant doit avoir au moins 50% de la taille du local

# Configuration des logs (rotation 2 semaines)
LOG_DIR="/var/log/zfs-nfs-replica"
LOG_RETENTION_DAYS=14

# Configuration de vérification de santé des pools
HEALTH_CHECK_MIN_FREE_SPACE=5  # Pourcentage minimum d'espace libre
HEALTH_CHECK_ERROR_COOLDOWN=3600  # Anti-ping-pong: 1 heure en secondes

# Configuration des notifications via Apprise
NOTIFICATION_ENABLED=true  # Activer/désactiver les notifications
NOTIFICATION_MODE="INFO"  # "INFO" (toutes les notifs) ou "ERROR" (erreurs uniquement)

# URLs Apprise (séparées par des espaces) - Exemples:
# Discord: discord://webhook_id/webhook_token
# Telegram: tgram://bot_token/chat_id
# Gotify: gotify://hostname/token
# Email: mailto://user:pass@smtp.domain.com
# Ntfy: ntfy://topic ou ntfy://hostname/topic
# Slack: slack://TokenA/TokenB/TokenC
# Voir https://github.com/caronc/apprise pour plus de services
APPRISE_URLS=""  # Configurer vos URLs ici

# Exemples d'utilisation:
# APPRISE_URLS="discord://webhook_id/token"
# APPRISE_URLS="discord://id/token gotify://server/token"
# APPRISE_URLS="mailto://user:pass@gmail.com tgram://bot_token/chat_id"

# Configuration environnement Python pour Apprise
APPRISE_VENV_DIR="${STATE_DIR}/venv"  # Répertoire du virtualenv Python
APPRISE_BIN="${APPRISE_VENV_DIR}/bin/apprise"  # Binaire Apprise dans le venv

# Initialiser le répertoire de logs
init_logging() {
    mkdir -p "$LOG_DIR"

    # Créer une configuration logrotate si elle n'existe pas
    local logrotate_conf="/etc/logrotate.d/zfs-nfs-replica"
    if [[ ! -f "$logrotate_conf" ]]; then
        cat > "$logrotate_conf" <<EOF
${LOG_DIR}/*.log {
    daily
    rotate ${LOG_RETENTION_DAYS}
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF
    fi
}

# Fonction de logging améliorée
log() {
    local level="$1"
    shift
    local pool="${CURRENT_POOL:-global}"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local message="[$timestamp] [$level] [$pool] $@"

    # Log vers syslog
    logger -t "zfs-nfs-replica" -p "${LOG_FACILITY}.${level}" "[$pool] $@"

    # Log vers stderr
    echo "$message" >&2

    # Log vers fichier (si pool spécifié)
    if [[ "$pool" != "global" ]]; then
        echo "$message" >> "${LOG_DIR}/${pool}.log"
    else
        echo "$message" >> "${LOG_DIR}/general.log"
    fi
}

# Initialisation de l'environnement Python pour Apprise
# Note: Le venv est persistant dans /var/lib/zfs-nfs-replica/venv
setup_apprise_venv() {
    # Créer le répertoire d'état si nécessaire
    mkdir -p "$STATE_DIR"

    # Vérifier si le venv existe déjà
    if [[ ! -d "$APPRISE_VENV_DIR" ]]; then
        log "info" "Création de l'environnement Python virtuel pour Apprise..."

        # Créer le virtualenv (python3 et venv sont préinstallés sur Proxmox)
        if ! python3 -m venv "$APPRISE_VENV_DIR" 2>/dev/null; then
            log "error" "Échec de la création du virtualenv"
            return 1
        fi

        log "info" "✓ Virtualenv créé: ${APPRISE_VENV_DIR}"

        # Installer pip dans le venv (pas installé par défaut sur Proxmox)
        log "info" "Installation de pip dans le virtualenv..."
        if ! "${APPRISE_VENV_DIR}/bin/python" -m ensurepip --upgrade >/dev/null 2>&1; then
            log "error" "Échec de l'installation de pip"
            return 1
        fi

        log "info" "✓ Pip installé dans le virtualenv"
    fi

    # Vérifier si Apprise est installé dans le venv
    if [[ ! -f "$APPRISE_BIN" ]]; then
        log "info" "Installation d'Apprise dans le virtualenv..."

        # Installer Apprise via pip du venv
        if "${APPRISE_VENV_DIR}/bin/pip" install --quiet apprise 2>/dev/null; then
            log "info" "✓ Apprise installé avec succès"
        else
            log "error" "Échec de l'installation d'Apprise"
            log "error" "Essayer manuellement: ${APPRISE_VENV_DIR}/bin/pip install apprise"
            return 1
        fi
    fi

    # Vérifier que Apprise fonctionne
    if [[ -x "$APPRISE_BIN" ]]; then
        local apprise_version
        apprise_version=$("$APPRISE_BIN" --version 2>/dev/null | head -1)
        log "info" "✓ Apprise prêt: ${apprise_version}"
        return 0
    else
        log "error" "Apprise installé mais non exécutable"
        return 1
    fi
}

# Fonction d'envoi de notifications via Apprise
send_notification() {
    local severity="$1"  # "info" ou "error"
    local title="$2"
    local message="$3"

    # Vérifier si les notifications sont activées
    if [[ "${NOTIFICATION_ENABLED}" != "true" ]]; then
        return 0
    fi

    # Vérifier si des URLs Apprise sont configurées
    if [[ -z "${APPRISE_URLS}" ]]; then
        return 0
    fi

    # Filtrer selon le mode de notification
    if [[ "${NOTIFICATION_MODE}" == "ERROR" ]] && [[ "$severity" != "error" ]]; then
        # Mode ERROR: ignorer les notifications info
        return 0
    fi

    # Vérifier si Apprise est installé dans le venv
    if [[ ! -x "$APPRISE_BIN" ]]; then
        log "warning" "Apprise non disponible - notifications désactivées"
        log "warning" "Le virtualenv n'a pas été correctement initialisé"
        return 1
    fi

    # Préparer le corps du message
    local hostname
    hostname=$(hostname)
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    local full_message="[${hostname}] [${timestamp}]
${message}

Script: zfs-nfs-replica v${SCRIPT_VERSION}
Nœud: ${hostname}"

    # Déterminer le type de notification Apprise selon la sévérité
    local notification_type="info"
    if [[ "$severity" == "error" ]]; then
        notification_type="warning"  # Apprise utilise "warning" pour les erreurs critiques
    fi

    # Envoyer la notification à tous les services configurés
    # apprise supporte plusieurs URLs séparées par des espaces
    if "$APPRISE_BIN" \
        --notification-type="$notification_type" \
        --title="ZFS NFS HA: ${title}" \
        --body="$full_message" \
        ${APPRISE_URLS} \
        >/dev/null 2>&1; then
        log "info" "Notification envoyée avec succès"
        return 0
    else
        log "warning" "Échec d'envoi de la notification via Apprise"
        return 1
    fi
}

# Fonction d'auto-update
auto_update() {
    # Vérifier si l'auto-update est activé
    if [[ "${AUTO_UPDATE_ENABLED}" != "true" ]]; then
        return 0
    fi

    # Éviter les boucles infinies en cas de problème
    if [[ "${SKIP_AUTO_UPDATE:-false}" == "true" ]]; then
        return 0
    fi

    log "info" "Vérification des mises à jour depuis ${REPO_URL}..."

    # Télécharger la version distante dans un fichier temporaire
    local temp_script
    temp_script=$(mktemp)

    if ! curl -sf -o "$temp_script" "$SCRIPT_URL" 2>/dev/null; then
        log "warning" "Impossible de vérifier les mises à jour (réseau ou dépôt inaccessible)"
        rm -f "$temp_script"
        return 0
    fi

    # Extraire la version du script distant
    local remote_version
    remote_version=$(grep '^SCRIPT_VERSION=' "$temp_script" | head -1 | cut -d'"' -f2)

    if [[ -z "$remote_version" ]]; then
        log "warning" "Impossible de déterminer la version distante"
        rm -f "$temp_script"
        return 0
    fi

    # Comparer les versions
    if [[ "$remote_version" == "$SCRIPT_VERSION" ]]; then
        log "info" "✓ Script à jour (version ${SCRIPT_VERSION})"
        rm -f "$temp_script"
        return 0
    fi

    log "warning" "Nouvelle version disponible: ${remote_version} (actuelle: ${SCRIPT_VERSION})"
    log "info" "Mise à jour automatique du script..."

    # Sauvegarder l'ancienne version
    local backup_script="${SCRIPT_PATH}.backup-${SCRIPT_VERSION}"
    if ! cp "$SCRIPT_PATH" "$backup_script"; then
        log "error" "Impossible de créer une sauvegarde, abandon de la mise à jour"
        rm -f "$temp_script"
        return 1
    fi

    # Remplacer le script par la nouvelle version
    if ! cp "$temp_script" "$SCRIPT_PATH"; then
        log "error" "Échec de la mise à jour, restauration de l'ancienne version"
        cp "$backup_script" "$SCRIPT_PATH"
        rm -f "$temp_script" "$backup_script"
        return 1
    fi

    # Vérifier les permissions
    chmod +x "$SCRIPT_PATH"
    rm -f "$temp_script"

    log "info" "✓ Mise à jour réussie vers la version ${remote_version}"
    log "info" "  Ancienne version sauvegardée: ${backup_script}"
    log "info" "  Redémarrage du script avec la nouvelle version..."

    # Relancer le script avec les mêmes arguments
    export SKIP_AUTO_UPDATE=true
    exec "$SCRIPT_PATH" "$@"
}

# Fonction de vérification du statut du LXC
check_lxc_running() {
    local attempt="$1"

    log "info" "Vérification #${attempt}/3 du statut du LXC ${CTID} (${CONTAINER_NAME})"

    # Vérifier que le CT existe
    if ! pct status "$CTID" &>/dev/null; then
        log "warning" "Le conteneur ${CTID} n'existe pas sur ce nœud"
        return 1
    fi

    # Vérifier le statut
    local status
    status=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')

    if [[ "$status" != "running" ]]; then
        log "info" "Le conteneur ${CTID} n'est pas en cours d'exécution (statut: ${status})"
        return 1
    fi

    # Vérification supplémentaire: le processus existe-t-il vraiment?
    if ! pct exec "$CTID" -- test -f /proc/1/cmdline 2>/dev/null; then
        log "warning" "Le conteneur ${CTID} semble running mais n'est pas responsive"
        return 1
    fi

    log "info" "Vérification #${attempt}/3 réussie: LXC ${CTID} est actif"
    return 0
}

# Triple vérification de sécurité
verify_lxc_is_active() {
    local check_count=0
    local success_count=0

    for i in 1 2 3; do
        check_count=$((check_count + 1))

        if check_lxc_running "$i"; then
            success_count=$((success_count + 1))
        else
            log "error" "Échec de la vérification #${i}/3"
            return 1
        fi

        # Délai entre les vérifications (sauf après la dernière)
        if [[ $i -lt 3 ]]; then
            sleep "$CHECK_DELAY"
        fi
    done

    if [[ $success_count -eq 3 ]]; then
        log "info" "✓ Triple vérification réussie: le LXC ${CTID} est définitivement actif sur ce nœud"
        return 0
    else
        log "error" "✗ Triple vérification échouée: ${success_count}/3 vérifications réussies"
        return 1
    fi
}

# Configuration dynamique de Sanoid selon le rôle
configure_sanoid() {
    local role="$1"  # "active" ou "passive"
    local autosnap_value="yes"

    if [[ "$role" == "passive" ]]; then
        autosnap_value="no"
        log "info" "Configuration de Sanoid en mode PASSIF (autosnap=no, autoprune=yes)"
    else
        log "info" "Configuration de Sanoid en mode ACTIF (autosnap=yes, autoprune=yes)"
    fi

    # Générer la configuration pour tous les pools
    cat > /etc/sanoid/sanoid.conf <<EOF
# Configuration automatique - Ne pas éditer manuellement
# Généré par zfs-nfs-replica.sh version ${SCRIPT_VERSION}
# Mode: ${role}

EOF

    # Ajouter chaque pool à la configuration
    for pool in "${ZPOOLS[@]}"; do
        cat >> /etc/sanoid/sanoid.conf <<EOF
[${pool}]
    use_template = production
    recursive = yes

EOF
    done

    # Ajouter le template
    cat >> /etc/sanoid/sanoid.conf <<EOF
[template_production]
    frequently = 48
    frequent_period = 15
    hourly = 48
    daily = 7
    monthly = 0
    yearly = 0
    autosnap = ${autosnap_value}
    autoprune = yes
EOF

    # Activer et démarrer Sanoid si nécessaire
    if systemctl is-enabled sanoid.timer &>/dev/null; then
        if ! systemctl is-active sanoid.timer &>/dev/null; then
            log "info" "Demarrage de Sanoid sur le noeud ${role}"
            systemctl start sanoid.timer
        fi
    else
        log "info" "Activation et demarrage de Sanoid sur le noeud ${role}"
        systemctl enable --now sanoid.timer
    fi
}

# Vérification de l'existence de snapshots en commun
check_common_snapshots() {
    local remote_ip="$1"
    local pool="$2"

    log "info" "Vérification des snapshots en commun entre les nœuds..."

    # Récupérer les snapshots locaux
    local local_snaps
    local_snaps=$(zfs list -t snapshot -r "$pool" -o name -H 2>/dev/null | sort || true)

    # Récupérer les snapshots distants
    local remote_snaps
    remote_snaps=$(ssh -i "$SSH_KEY" "root@${remote_ip}" "zfs list -t snapshot -r ${pool} -o name -H 2>/dev/null | sort" || true)

    # Si pas de snapshots distants, c'est une première sync
    if [[ -z "$remote_snaps" ]]; then
        log "warning" "Aucun snapshot trouvé sur le nœud distant"
        return 1
    fi

    # Si pas de snapshots locaux (ne devrait pas arriver avec Sanoid actif)
    if [[ -z "$local_snaps" ]]; then
        log "warning" "Aucun snapshot trouvé sur le nœud local"
        return 1
    fi

    # Chercher des snapshots en commun
    local common_snaps
    common_snaps=$(comm -12 <(echo "$local_snaps") <(echo "$remote_snaps"))

    if [[ -n "$common_snaps" ]]; then
        local count
        count=$(echo "$common_snaps" | wc -l)
        log "info" "✓ ${count} snapshot(s) en commun trouvé(s)"
        return 0
    else
        log "warning" "✗ Aucun snapshot en commun trouvé"
        return 1
    fi
}

# Extraction des UUIDs des disques physiques d'un pool
get_pool_disk_uuids() {
    local pool="$1"

    # Obtenir la configuration du pool avec chemins physiques
    local pool_config
    pool_config=$(zpool status -P "$pool" 2>/dev/null)

    if [[ -z "$pool_config" ]]; then
        return 1
    fi

    # Extraire les devices physiques (lignes contenant /dev/)
    # Format typique: "  /dev/sdb1  ONLINE  0  0  0"
    local devices
    devices=$(echo "$pool_config" | grep -E '^\s+/dev/' | awk '{print $1}')

    if [[ -z "$devices" ]]; then
        # Pool virtuel ou pas de disques physiques
        return 0
    fi

    # Pour chaque device, résoudre vers /dev/disk/by-id/ (méthode optimisée)
    local uuids=()
    while read -r device; do
        if [[ -z "$device" ]]; then
            continue
        fi

        # Résoudre le device réel
        local device_real
        device_real=$(readlink -f "$device" 2>/dev/null)

        if [[ -z "$device_real" ]]; then
            continue
        fi

        # Chercher les liens dans /dev/disk/by-id/ pointant vers ce device
        # Méthode optimisée: ls -l au lieu de find
        local found_uuids
        found_uuids=$(ls -l /dev/disk/by-id/ 2>/dev/null | \
                      awk -v target="$(basename "$device_real")" '$NF == target {print $(NF-2)}' | \
                      grep -E '^(wwn-|ata-|scsi-|nvme-)' || true)

        if [[ -n "$found_uuids" ]]; then
            while read -r uuid_name; do
                uuids+=("$uuid_name")
            done <<< "$found_uuids"
        fi
    done <<< "$devices"

    # Retourner les UUIDs triés et uniques
    if [[ ${#uuids[@]} -gt 0 ]]; then
        printf '%s\n' "${uuids[@]}" | sort -u
        return 0
    else
        # Aucun UUID trouvé (pool virtuel possible)
        return 0
    fi
}

# Initialisation du tracking des disques pour un pool
init_disk_tracking() {
    local pool="$1"
    local uuids_file="${STATE_DIR}/disk-uuids-${pool}.txt"

    # Vérifier si déjà initialisé
    if [[ -f "$uuids_file" ]] && grep -q "^initialized=true" "$uuids_file" 2>/dev/null; then
        log "info" "Tracking des disques déjà initialisé pour ${pool}"
        return 0
    fi

    log "info" "Initialisation du tracking des disques pour ${pool}"

    # Créer le répertoire d'état si nécessaire
    mkdir -p "$STATE_DIR"

    # Obtenir les UUIDs des disques du pool
    local uuids
    uuids=$(get_pool_disk_uuids "$pool")

    if [[ -z "$uuids" ]]; then
        log "warning" "Aucun disque physique détecté pour ${pool} (pool virtuel?)"
        # Créer quand même un fichier pour marquer comme initialisé
        cat > "$uuids_file" <<EOF
initialized=true
timestamp=$(date '+%Y-%m-%d_%H:%M:%S')
hostname=$(hostname)
pool=${pool}
vdev_type=virtual
# Aucun disque physique détecté
EOF
        chmod 600 "$uuids_file"
        chown root:root "$uuids_file" 2>/dev/null
        return 0
    fi

    # Créer le fichier de tracking
    cat > "$uuids_file" <<EOF
initialized=true
timestamp=$(date '+%Y-%m-%d_%H:%M:%S')
hostname=$(hostname)
pool=${pool}
# Physical disk UUIDs
EOF

    # Ajouter chaque UUID
    while read -r uuid; do
        echo "$uuid" >> "$uuids_file"
        log "info" "Disque détecté pour ${pool}: ${uuid}"
    done <<< "$uuids"

    # Définir les permissions
    chmod 600 "$uuids_file"
    chown root:root "$uuids_file" 2>/dev/null

    local disk_count
    disk_count=$(echo "$uuids" | wc -l)
    log "info" "✓ Tracking des disques initialisé pour ${pool}: ${disk_count} disque(s) enregistré(s)"

    return 0
}

# Vérification de la présence des disques trackés
verify_disk_presence() {
    local pool="$1"
    local uuids_file="${STATE_DIR}/disk-uuids-${pool}.txt"

    if [[ ! -f "$uuids_file" ]]; then
        log "error" "Fichier de tracking des disques non trouvé: ${uuids_file}"
        return 1
    fi

    # Lire les UUIDs du fichier (ignorer les lignes de commentaires et metadata)
    local tracked_uuids
    tracked_uuids=$(grep -E '^(wwn-|ata-|scsi-|nvme-)' "$uuids_file" 2>/dev/null)

    if [[ -z "$tracked_uuids" ]]; then
        # Pool virtuel, pas de vérification nécessaire
        log "info" "Pool ${pool}: aucun disque physique à vérifier (pool virtuel)"
        return 0
    fi

    # Vérifier chaque UUID
    local missing_disks=0
    while read -r uuid; do
        local disk_path="/dev/disk/by-id/${uuid}"

        if [[ ! -L "$disk_path" ]]; then
            log "error" "Disque manquant pour ${pool}: ${uuid}"
            log "error" "  Emplacement attendu: ${disk_path}"
            missing_disks=$((missing_disks + 1))
        elif [[ ! -e "$disk_path" ]]; then
            log "error" "Symlink dangling pour ${pool}: ${uuid}"
            log "error" "  Le lien existe mais pointe vers un device inexistant"
            missing_disks=$((missing_disks + 1))
        fi
    done <<< "$tracked_uuids"

    if [[ $missing_disks -gt 0 ]]; then
        log "error" "✗ ${missing_disks} disque(s) manquant(s) pour ${pool}"
        send_notification "error" "Disque(s) manquant(s) - ${pool}" \
            "${missing_disks} disque(s) manquant(s) détecté(s) pour le pool ${pool}.

Vérifier les connexions USB/SATA et l'état des disques.
Une migration automatique du LXC peut être déclenchée."
        return 1
    else
        log "info" "✓ Tous les disques présents pour ${pool}"
        return 0
    fi
}

# Vérification de l'état de santé du pool ZFS
check_pool_health_status() {
    local pool="$1"
    local health_issues=0

    # Check 1: Status du pool (ONLINE/DEGRADED/FAULTED)
    local pool_health
    pool_health=$(zpool list -H -o health "$pool" 2>/dev/null)

    if [[ -z "$pool_health" ]]; then
        log "error" "Impossible de récupérer le status du pool ${pool}"
        return 1
    fi

    if [[ "$pool_health" != "ONLINE" ]]; then
        log "error" "Pool ${pool} en état dégradé: ${pool_health}"
        send_notification "error" "Pool ZFS ${pool_health} - ${pool}" \
            "Le pool ZFS ${pool} est en état ${pool_health}.

Vérifier l'état des disques avec: zpool status ${pool}
Une migration automatique du LXC peut être déclenchée."
        health_issues=$((health_issues + 1))
    else
        log "info" "✓ Pool ${pool} status: ONLINE"
    fi

    # Check 2: Espace libre (doit être > HEALTH_CHECK_MIN_FREE_SPACE%)
    local capacity
    capacity=$(zpool list -H -o capacity "$pool" 2>/dev/null | sed 's/%//')

    if [[ -n "$capacity" ]]; then
        local min_capacity=$((100 - HEALTH_CHECK_MIN_FREE_SPACE))

        if [[ $capacity -ge $min_capacity ]]; then
            log "error" "Espace disque critique pour ${pool}: ${capacity}% utilisé (seuil: ${min_capacity}%)"
            send_notification "error" "Espace disque critique - ${pool}" \
                "Le pool ${pool} est presque plein: ${capacity}% utilisé.

Seuil critique: ${min_capacity}%
Espace libre restant: $((100 - capacity))%

ACTION REQUISE: Libérer de l'espace ou agrandir le pool."
            health_issues=$((health_issues + 1))
        else
            local free_percent=$((100 - capacity))
            log "info" "✓ Espace libre pour ${pool}: ${free_percent}% (seuil minimum: ${HEALTH_CHECK_MIN_FREE_SPACE}%)"
        fi
    fi

    # Check 3: Scrub/resilver en cours (non bloquant, juste informatif)
    if zpool status "$pool" 2>/dev/null | grep -qi "scrub in progress"; then
        log "warning" "Scrub en cours sur ${pool} (non bloquant)"
    fi

    if zpool status "$pool" 2>/dev/null | grep -qi "resilver in progress"; then
        log "warning" "Resilver en cours sur ${pool} (non bloquant)"
    fi

    # Check 4: Erreurs I/O (READ/WRITE/CKSUM)
    local error_lines
    error_lines=$(zpool status "$pool" 2>/dev/null | grep -E "errors:" | grep -v "No known data errors")

    if [[ -n "$error_lines" ]]; then
        log "error" "Erreurs détectées sur le pool ${pool}:"
        zpool status "$pool" 2>/dev/null | grep -E "(READ|WRITE|CKSUM)" | while read -r line; do
            log "error" "  ${line}"
        done
        health_issues=$((health_issues + 1))
    else
        log "info" "✓ Aucune erreur I/O détectée sur ${pool}"
    fi

    if [[ $health_issues -eq 0 ]]; then
        return 0
    else
        log "error" "✗ ${health_issues} problème(s) de santé détecté(s) sur ${pool}"
        return 1
    fi
}

# Récupération des tailles de datasets
get_dataset_sizes() {
    local target="$1"  # "local" ou "remote:IP"
    local pool="$2"

    if [[ "$target" == "local" ]]; then
        zfs list -r "$pool" -o name,used -Hp 2>/dev/null || true
    else
        local remote_ip="${target#remote:}"
        ssh -i "$SSH_KEY" "root@${remote_ip}" "zfs list -r ${pool} -o name,used -Hp 2>/dev/null" || true
    fi
}

# Sauvegarde des tailles de datasets après sync réussie
save_dataset_sizes() {
    local pool="$1"
    local sizes_file="${STATE_DIR}/last-sync-sizes-${pool}.txt"

    log "info" "Sauvegarde des tailles de datasets dans ${sizes_file}"

    # Créer le répertoire si nécessaire
    mkdir -p "$STATE_DIR"

    # Sauvegarder avec timestamp
    {
        echo "timestamp=$(date '+%Y-%m-%d_%H:%M:%S')"
        get_dataset_sizes "local" "$pool" | awk '{print $1"="$2}'
    } > "$sizes_file"

    log "info" "✓ Tailles sauvegardées"
}

# Vérification de sécurité des tailles avant --force-delete
check_size_safety() {
    local remote_ip="$1"
    local pool="$2"
    local sizes_file="${STATE_DIR}/last-sync-sizes-${pool}.txt"

    log "info" "=== Vérifications de sécurité avant --force-delete ==="

    # Récupérer les tailles actuelles
    local local_sizes
    local_sizes=$(get_dataset_sizes "local" "$pool")

    local remote_sizes
    remote_sizes=$(get_dataset_sizes "remote:${remote_ip}" "$pool")

    if [[ -z "$local_sizes" ]] || [[ -z "$remote_sizes" ]]; then
        log "error" "✗ Impossible de récupérer les tailles des datasets"
        return 1
    fi

    # Vérifier si un historique existe (indique que ce nœud a déjà été actif)
    local has_history=false
    if [[ -f "$sizes_file" ]]; then
        has_history=true
    fi

    # === SÉCURITÉ 1 : Comparaison source/destination ===
    # Cette vérification s'applique UNIQUEMENT s'il existe un historique
    # (pour éviter de bloquer la première installation légitime)
    if [[ "$has_history" == "true" ]]; then
        log "info" "Vérification #1: Comparaison des tailles source/destination (historique détecté)"

        local dataset size_local size_remote ratio
        while IFS=$'\t' read -r dataset size_local; do
            # Trouver la taille correspondante sur le distant
            size_remote=$(echo "$remote_sizes" | grep "^${dataset}" | awk '{print $2}')

            if [[ -n "$size_remote" ]]; then
                # Protection contre division par zéro et source plus petite que destination
                if [[ "$size_local" -eq 0 ]] && [[ "$size_remote" -gt 0 ]]; then
                    log "error" "✗ SÉCURITÉ: Dataset ${dataset}"
                    log "error" "  Local (source): 0B (VIDE)"
                    log "error" "  Distant (destination): $(numfmt --to=iec-i --suffix=B "$size_remote")"
                    log "error" "  Le nœud LOCAL est vide alors que le DISTANT contient des données"
                    log "error" "  Cela indiquerait un disque de remplacement vide devenu actif par erreur"
                    log "error" "  REFUS de --force-delete pour éviter d'écraser les données du nœud distant"
                    return 1
                fi

                if [[ "$size_local" -gt 0 ]]; then
                    # Calculer le ratio distant/local (le distant doit avoir au moins 50% du local)
                    ratio=$((size_remote * 100 / size_local))

                    if [[ $ratio -lt $MIN_REMOTE_RATIO ]]; then
                        log "error" "✗ SÉCURITÉ: Dataset ${dataset}"
                        log "error" "  Local (source): $(numfmt --to=iec-i --suffix=B "$size_local")"
                        log "error" "  Distant (destination): $(numfmt --to=iec-i --suffix=B "$size_remote")"
                        log "error" "  Ratio: ${ratio}% (minimum requis: ${MIN_REMOTE_RATIO}%)"
                        log "error" "  Le nœud distant semble avoir des données incomplètes ou vides"
                        log "error" "  REFUS de --force-delete pour éviter la perte de données"
                        return 1
                    fi

                    # Vérification inverse : source ne doit pas être significativement plus petite que destination
                    local inverse_ratio
                    inverse_ratio=$((size_local * 100 / size_remote))

                    if [[ $inverse_ratio -lt $MIN_REMOTE_RATIO ]]; then
                        log "error" "✗ SÉCURITÉ: Dataset ${dataset}"
                        log "error" "  Local (source): $(numfmt --to=iec-i --suffix=B "$size_local")"
                        log "error" "  Distant (destination): $(numfmt --to=iec-i --suffix=B "$size_remote")"
                        log "error" "  Ratio inverse: ${inverse_ratio}% (minimum requis: ${MIN_REMOTE_RATIO}%)"
                        log "error" "  La SOURCE est plus petite que la DESTINATION"
                        log "error" "  Cela indiquerait un disque de remplacement devenu actif par erreur"
                        log "error" "  REFUS de --force-delete pour éviter d'écraser des données avec un disque vide"
                        return 1
                    fi
                fi
            fi
        done <<< "$local_sizes"

        log "info" "✓ Vérification #1 réussie: Les tailles sont cohérentes entre les nœuds"
    else
        log "info" "Vérification #1 ignorée: Première activation de ce nœud (pas d'historique)"
        log "info" "  Il est normal que le nœud distant soit vide lors de la première installation"
    fi

    # === SÉCURITÉ 2 : Comparaison avec historique ===
    if [[ "$has_history" == "true" ]]; then
        log "info" "Vérification #2: Comparaison avec l'historique des tailles"

        local previous_timestamp
        previous_timestamp=$(grep "^timestamp=" "$sizes_file" | cut -d= -f2)
        log "info" "Dernière synchronisation réussie: ${previous_timestamp}"

        local dataset size_remote size_previous diff_percent
        while IFS=$'\t' read -r dataset size_remote; do
            # Récupérer la taille précédente
            size_previous=$(grep "^${dataset}=" "$sizes_file" | cut -d= -f2)

            if [[ -n "$size_previous" ]] && [[ "$size_previous" -gt 0 ]]; then
                # Calculer la différence en pourcentage
                local diff
                diff=$((size_remote > size_previous ? size_remote - size_previous : size_previous - size_remote))
                diff_percent=$((diff * 100 / size_previous))

                if [[ $diff_percent -gt $SIZE_TOLERANCE ]]; then
                    log "error" "✗ SÉCURITÉ: Dataset ${dataset}"
                    log "error" "  Taille précédente: $(numfmt --to=iec-i --suffix=B "$size_previous")"
                    log "error" "  Taille actuelle: $(numfmt --to=iec-i --suffix=B "$size_remote")"
                    log "error" "  Variation: ${diff_percent}% (tolérance: ±${SIZE_TOLERANCE}%)"
                    log "error" "  Variation anormale détectée depuis la dernière sync"
                    log "error" "  REFUS de --force-delete pour éviter la perte de données"
                    return 1
                fi
            fi
        done <<< "$remote_sizes"

        log "info" "✓ Vérification #2 réussie: Les tailles sont cohérentes avec l'historique"
    else
        log "info" "Vérification #2 ignorée: Pas d'historique de tailles (première activation)"
    fi

    log "info" "=== ✓ Toutes les vérifications de sécurité sont passées ==="
    log "info" "=== Autorisation de --force-delete accordée ==="
    return 0
}

# Triple vérification de santé (mirroring verify_lxc_is_active pattern)
triple_health_check() {
    local pool="$1"
    local success_count=0

    for i in 1 2 3; do
        log "info" "Vérification santé #${i}/3 pour ${pool}"

        # Vérifier à la fois la présence des disques ET l'état du pool
        if verify_disk_presence "$pool" && check_pool_health_status "$pool"; then
            success_count=$((success_count + 1))
            log "info" "Vérification santé #${i}/3 réussie pour ${pool}"
        else
            log "error" "Vérification santé #${i}/3 échouée pour ${pool}"
        fi

        # Délai entre les vérifications (sauf après la dernière)
        if [[ $i -lt 3 ]]; then
            sleep "$CHECK_DELAY"
        fi
    done

    if [[ $success_count -eq 3 ]]; then
        log "info" "✓ Triple vérification santé réussie pour ${pool} (${success_count}/3)"
        return 0
    else
        log "error" "✗ Triple vérification santé échouée pour ${pool}: ${success_count}/3 vérifications réussies"
        return 1
    fi
}

# Vérification de l'existence d'une erreur critique récente (anti-ping-pong)
check_recent_critical_error() {
    local pool="$1"
    local error_file="${STATE_DIR}/critical-errors-${pool}.txt"

    if [[ ! -f "$error_file" ]]; then
        # Pas d'erreur précédente
        return 1
    fi

    # Lire le timestamp epoch de la dernière erreur
    local last_error_epoch
    last_error_epoch=$(grep "^epoch=" "$error_file" | cut -d= -f2)

    if [[ -z "$last_error_epoch" ]]; then
        # Fichier corrompu ou format invalide
        return 1
    fi

    # Calculer le temps écoulé depuis la dernière erreur
    local current_epoch
    current_epoch=$(date +%s)
    local time_diff=$((current_epoch - last_error_epoch))

    if [[ $time_diff -lt $HEALTH_CHECK_ERROR_COOLDOWN ]]; then
        # Erreur récente (< 1 heure par défaut)
        log "warning" "Erreur critique récente détectée: il y a ${time_diff}s (seuil: ${HEALTH_CHECK_ERROR_COOLDOWN}s)"
        return 0
    else
        # Erreur ancienne (> 1 heure)
        log "info" "Dernière erreur critique: il y a ${time_diff}s (> seuil de ${HEALTH_CHECK_ERROR_COOLDOWN}s)"
        return 1
    fi
}

# Enregistrement d'une erreur critique
record_critical_error() {
    local pool="$1"
    local reason="$2"
    local action="$3"  # "lxc_migrated" ou "lxc_stopped" ou "lxc_stopped_failsafe"
    local error_file="${STATE_DIR}/critical-errors-${pool}.txt"

    # Créer le répertoire d'état si nécessaire
    mkdir -p "$STATE_DIR"

    # Créer ou écraser le fichier d'erreur
    cat > "$error_file" <<EOF
timestamp=$(date '+%Y-%m-%d_%H:%M:%S')
epoch=$(date +%s)
reason=${reason}
action=${action}
target_node=${REMOTE_NODE_NAME}
EOF

    # Définir les permissions
    chmod 600 "$error_file"
    chown root:root "$error_file" 2>/dev/null

    log "error" "Erreur critique enregistrée pour ${pool}: ${reason} → ${action}"
}

# Gestion de l'échec de santé - Migration ou arrêt du LXC
handle_health_failure() {
    local pool="$1"
    local failure_reason="$2"

    # Log box pour visibilité maximale
    log "error" "╔════════════════════════════════════════════════════════════╗"
    log "error" "║ ÉCHEC CRITIQUE DE SANTÉ POUR ${pool}"
    log "error" "║ Raison: ${failure_reason}"
    log "error" "╚════════════════════════════════════════════════════════════╝"

    # Vérifier s'il y a eu une erreur récente (mécanisme anti-ping-pong)
    if check_recent_critical_error "$pool"; then
        local last_error_time
        last_error_time=$(grep "^timestamp=" "${STATE_DIR}/critical-errors-${pool}.txt" | cut -d= -f2)

        log "error" "Erreur critique récente détectée (${last_error_time})"
        log "error" "Action: ARRÊT du LXC ${CTID} pour éviter ping-pong"

        # Arrêter le LXC
        if pct stop "$CTID" >/dev/null 2>&1; then
            log "error" "✓ LXC ${CTID} arrêté avec succès"
            send_notification "error" "Arrêt LXC (anti-ping-pong)" \
                "Le LXC ${CTID} a été arrêté pour éviter un ping-pong.

Pool: ${pool}
Raison: ${failure_reason}
Erreur précédente: ${last_error_time}

ACTION REQUISE: Vérifier l'état des disques et pools sur les deux nœuds avant de redémarrer le LXC."
            record_critical_error "$pool" "$failure_reason" "lxc_stopped"
            return 0
        else
            log "error" "✗ Échec de l'arrêt du LXC ${CTID}"
            record_critical_error "$pool" "$failure_reason" "lxc_stop_failed"
            return 1
        fi
    else
        # Première erreur ou erreur ancienne (> 1 heure)
        log "warning" "Première erreur ou erreur ancienne (> ${HEALTH_CHECK_ERROR_COOLDOWN}s)"
        log "warning" "Action: MIGRATION du LXC ${CTID} vers ${REMOTE_NODE_NAME}"

        # Tenter la migration via HA
        if ha-manager migrate "ct:${CTID}" "$REMOTE_NODE_NAME" >/dev/null 2>&1; then
            log "warning" "✓ Migration HA initiée vers ${REMOTE_NODE_NAME}"
            send_notification "error" "Migration LXC vers ${REMOTE_NODE_NAME}" \
                "Le LXC ${CTID} a été migré vers ${REMOTE_NODE_NAME} suite à un problème de santé.

Pool: ${pool}
Raison: ${failure_reason}
Nœud source: $(hostname)
Nœud destination: ${REMOTE_NODE_NAME}

Le service NFS devrait continuer à fonctionner sur le nœud distant."
            record_critical_error "$pool" "$failure_reason" "lxc_migrated"
            return 0
        else
            log "error" "✗ Échec de la migration HA vers ${REMOTE_NODE_NAME}"
            log "error" "Tentative d'arrêt du LXC en dernier recours"

            # Fallback: arrêter le LXC si la migration échoue
            if pct stop "$CTID" >/dev/null 2>&1; then
                log "error" "✓ LXC ${CTID} arrêté en dernier recours"
                record_critical_error "$pool" "$failure_reason" "lxc_stopped_failsafe"
                return 0
            else
                log "error" "✗ Échec critique: impossible de migrer ou d'arrêter le LXC ${CTID}"
                record_critical_error "$pool" "$failure_reason" "all_actions_failed"
                return 1
            fi
        fi
    fi
}

# Orchestrateur principal de vérification de santé d'un pool
verify_pool_health() {
    local pool="$1"

    export CURRENT_POOL="$pool"
    log "info" "=========================================="
    log "info" "Vérification de santé du pool: ${pool}"
    log "info" "=========================================="

    # Étape 1: Initialiser le tracking des disques si nécessaire
    local uuids_file="${STATE_DIR}/disk-uuids-${pool}.txt"
    if [[ ! -f "$uuids_file" ]] || ! grep -q "^initialized=true" "$uuids_file" 2>/dev/null; then
        log "info" "Première exécution: initialisation du suivi des disques pour ${pool}"

        if ! init_disk_tracking "$pool"; then
            log "warning" "Impossible d'initialiser le suivi des disques pour ${pool}"
            log "info" "Continuation sans vérification des disques (pool virtuel possible)"
            # Ne pas échouer pour les pools virtuels
            return 0
        fi
    fi

    # Étape 2: Triple vérification de santé
    if ! triple_health_check "$pool"; then
        log "error" "Triple vérification de santé échouée pour ${pool}"

        # Déterminer la raison de l'échec pour un message d'erreur précis
        local failure_reason="Vérification de santé échouée"

        # Tenter de déterminer la cause spécifique
        if ! verify_disk_presence "$pool"; then
            failure_reason="Disque(s) manquant(s) détecté(s)"
        elif ! check_pool_health_status "$pool"; then
            # Obtenir plus de détails sur le problème de pool
            local pool_health
            pool_health=$(zpool list -H -o health "$pool" 2>/dev/null)
            if [[ "$pool_health" != "ONLINE" ]]; then
                failure_reason="Pool en état ${pool_health}"
            else
                failure_reason="État du pool non nominal (espace disque ou erreurs I/O)"
            fi
        fi

        # Gérer l'échec (migration ou arrêt du LXC)
        handle_health_failure "$pool" "$failure_reason"
        return 1
    fi

    log "info" "✓ Vérification de santé réussie pour ${pool}"
    return 0
}

# Fonction de réplication d'un pool
replicate_pool() {
    local pool="$1"
    local remote_ip="$2"
    local remote_name="$3"

    export CURRENT_POOL="$pool"
    log "info" "=========================================="
    log "info" "Début de la réplication du pool: ${pool}"
    log "info" "=========================================="

    # Vérification de l'existence du pool
    if ! zpool list "$pool" &>/dev/null; then
        log "error" "Le pool ${pool} n'existe pas sur ce nœud - IGNORÉ"
        return 1
    fi

    # Verrou pour éviter les réplications concurrentes de ce pool
    local lockfile="/var/run/zfs-replica-${pool}.lock"
    local lockfd=201

    # Tentative d'acquisition du verrou (non-bloquant)
    eval "exec ${lockfd}>${lockfile}"
    if ! flock -n ${lockfd}; then
        log "info" "Une réplication de ${pool} est déjà en cours - IGNORÉ"
        return 0
    fi

    log "info" "Verrou acquis pour ${pool}"

    # Vérification que le pool existe sur le nœud distant
    if ! ssh -i "$SSH_KEY" "root@${remote_ip}" "zpool list ${pool}" &>/dev/null; then
        log "error" "Le pool ${pool} n'existe pas sur ${remote_name}"
        flock -u ${lockfd}
        return 1
    fi

    # Vérification des snapshots en commun et choix de la stratégie
    log "info" "Début de la réplication récursive: ${pool} → ${remote_name} (${remote_ip}):${pool}"

    # Syncoid utilise les options SSH via la variable d'environnement SSH
    export SSH="ssh -i ${SSH_KEY}"

    local syncoid_opts
    # Déterminer si c'est une première synchronisation
    if check_common_snapshots "$remote_ip" "$pool"; then
        # Snapshots en commun : réplication incrémentale normale
        log "info" "Mode: Réplication incrémentale (snapshots en commun détectés)"
        syncoid_opts="--recursive --no-sync-snap"
    else
        # Pas de snapshots en commun : première synchronisation avec --force-delete
        log "warning" "Mode: Première synchronisation détectée"
        log "warning" "Utilisation de --force-delete pour écraser les datasets incompatibles"

        # SÉCURITÉ : Vérifier les tailles avant d'autoriser --force-delete
        if ! check_size_safety "$remote_ip" "$pool"; then
            log "error" "╔════════════════════════════════════════════════════════════════╗"
            log "error" "║ ARRÊT DE SÉCURITÉ pour ${pool}                                ║"
            log "error" "║ Les vérifications de sécurité ont échoué.                     ║"
            log "error" "║ --force-delete REFUSÉ pour éviter une perte de données.       ║"
            log "error" "╚════════════════════════════════════════════════════════════════╝"
            flock -u ${lockfd}
            return 1
        fi

        syncoid_opts="--recursive --force-delete"
    fi

    # Lister les datasets de premier niveau sous le pool
    local first_level_datasets
    first_level_datasets=$(zfs list -H -o name -r "$pool" -t filesystem,volume -d 1 | grep -v "^${pool}$")

    if [[ -z "$first_level_datasets" ]]; then
        log "error" "Aucun dataset trouvé sous ${pool}"
        flock -u ${lockfd}
        return 1
    fi

    log "info" "Datasets à répliquer:"
    while read -r dataset; do
        log "info" "  - ${dataset}"
    done <<< "$first_level_datasets"

    # Lancer la réplication pour chaque dataset de premier niveau
    local replication_failed=0
    local datasets_processed=0

    while read -r dataset; do
        datasets_processed=$((datasets_processed + 1))
        log "info" "=== Réplication de ${dataset} (récursif) ==="

        if syncoid $syncoid_opts "$dataset" "root@${remote_ip}:${dataset}" < /dev/null; then
            log "info" "✓ ${dataset} répliqué avec succès"
        else
            log "error" "✗ Échec de la réplication de ${dataset}"
            replication_failed=1
        fi
    done <<< "$first_level_datasets"

    log "info" "Nombre de datasets traités: ${datasets_processed}"

    # Libérer le verrou
    flock -u ${lockfd}

    if [[ $replication_failed -eq 0 ]]; then
        log "info" "✓ Réplication récursive réussie vers ${remote_name} (${remote_ip})"
        log "info" "  Tous les datasets de ${pool} ont été synchronisés"

        # Sauvegarder les tailles après sync réussie
        save_dataset_sizes "$pool"

        return 0
    else
        log "error" "✗ Échec de la réplication de ${pool} vers ${remote_name} (${remote_ip})"
        return 1
    fi
}

################################################################################
# SCRIPT PRINCIPAL
################################################################################

# Ne pas exécuter le script principal si on est en mode test BATS
if [[ "${BATS_TEST_MODE:-false}" == "true" ]]; then
    return 0 2>/dev/null || exit 0
fi

# Initialiser le système de logs
init_logging

# Détermination du nœud local et distant
LOCAL_NODE=$(hostname)
export CURRENT_POOL="global"
log "info" "=========================================="
log "info" "Démarrage du script version ${SCRIPT_VERSION}"
log "info" "Nœud: ${LOCAL_NODE}"
log "info" "=========================================="

# Vérifier les mises à jour (avant toute opération)
auto_update "$@"

# Vérifier et initialiser la configuration des notifications
if [[ "${NOTIFICATION_ENABLED}" == "true" ]] && [[ -n "${APPRISE_URLS}" ]]; then
    log "info" "Initialisation du système de notifications..."

    # Initialiser l'environnement Python et installer Apprise si nécessaire
    if setup_apprise_venv; then
        local url_count
        url_count=$(echo "${APPRISE_URLS}" | wc -w)
        log "info" "✓ Notifications activées: ${url_count} service(s) configuré(s)"
        log "info" "  Mode: ${NOTIFICATION_MODE}"
    else
        log "warning" "Échec de l'initialisation d'Apprise - notifications désactivées"
        NOTIFICATION_ENABLED=false
    fi
elif [[ "${NOTIFICATION_ENABLED}" == "true" ]] && [[ -z "${APPRISE_URLS}" ]]; then
    log "info" "Notifications activées mais aucune URL Apprise configurée (APPRISE_URLS vide)"
    log "info" "Configurer APPRISE_URLS dans le script pour recevoir des notifications"
fi

# Déterminer le nœud distant et son IP
# Vérifier que le nœud local est dans la configuration
if [[ ! -v "CLUSTER_NODES[$LOCAL_NODE]" ]]; then
    local valid_nodes="${!CLUSTER_NODES[@]}"
    log "error" "Nœud inconnu: ${LOCAL_NODE}. Nœuds valides: ${valid_nodes}"
    exit 1
fi

# Trouver le nœud distant (le premier nœud différent du local)
REMOTE_NODE_NAME=""
REMOTE_NODE_IP=""
for node in "${!CLUSTER_NODES[@]}"; do
    if [[ "$node" != "$LOCAL_NODE" ]]; then
        REMOTE_NODE_NAME="$node"
        REMOTE_NODE_IP="${CLUSTER_NODES[$node]}"
        break
    fi
done

# Vérifier qu'un nœud distant a été trouvé
if [[ -z "$REMOTE_NODE_NAME" ]]; then
    log "error" "Aucun nœud distant trouvé dans CLUSTER_NODES. Vérifier la configuration."
    exit 1
fi

log "info" "Nœud distant configuré: ${REMOTE_NODE_NAME} (${REMOTE_NODE_IP})"
log "info" "Pools configurés: ${ZPOOLS[*]}"

# Triple vérification de sécurité
if ! verify_lxc_is_active; then
    log "info" "Le LXC ${CTID} n'est pas actif sur ce nœud. Pas de réplication nécessaire."

    # Vérification de santé des pools sur nœud passif
    log "info" "Vérification de santé des pools (nœud passif)"
    PASSIVE_HEALTH_FAILED=false
    for pool in "${ZPOOLS[@]}"; do
        if ! verify_pool_health "$pool"; then
            log "warning" "⚠ Pool ${pool} en mauvaise santé sur nœud PASSIF"
            send_notification "error" "Pool dégradé sur nœud passif" \
                "Pool: ${pool}\nNœud: ${LOCAL_NODE}\nStatut: PASSIF\n\nLe pool est dégradé mais ce nœud est passif. Vérifier l'état du matériel avant un éventuel failover."
            PASSIVE_HEALTH_FAILED=true
        fi
    done

    if [[ "$PASSIVE_HEALTH_FAILED" == "false" ]]; then
        log "info" "✓ Tous les pools sont en bonne santé (nœud passif)"
    fi

    # Configurer Sanoid en mode passif
    configure_sanoid "passive"
    exit 0
fi

# Le LXC est actif ici : configurer Sanoid en mode actif
configure_sanoid "active"

# Vérification de la connectivité SSH vers le nœud distant
if ! ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o BatchMode=yes "root@${REMOTE_NODE_IP}" "echo OK" &>/dev/null; then
    log "error" "Impossible de se connecter à ${REMOTE_NODE_NAME} (${REMOTE_NODE_IP}) via SSH"
    exit 1
fi

log "info" "Connexion SSH vers ${REMOTE_NODE_NAME} (${REMOTE_NODE_IP}) vérifiée"

# Vérification de santé des pools
log "info" "=========================================="
log "info" "Vérification de santé des pools"
log "info" "=========================================="

HEALTH_CHECK_FAILED=false
for pool in "${ZPOOLS[@]}"; do
    if ! verify_pool_health "$pool"; then
        log "error" "Vérification de santé échouée pour ${pool}"
        HEALTH_CHECK_FAILED=true
    fi
done

# Arrêt si échec de santé détecté
if [[ "$HEALTH_CHECK_FAILED" == "true" ]]; then
    export CURRENT_POOL="global"
    log "error" "Arrêt du script suite à échec(s) de vérification de santé"
    log "error" "Le LXC a été migré ou arrêté pour protection"
    exit 1
fi

log "info" "✓ Tous les pools sont en bonne santé"

# Compteurs globaux
POOLS_TOTAL=${#ZPOOLS[@]}
POOLS_SUCCESS=0
POOLS_FAILED=0
POOLS_SKIPPED=0

log "info" "=========================================="
log "info" "Début de la réplication de ${POOLS_TOTAL} pool(s)"
log "info" "=========================================="

# Réplication de chaque pool
for pool in "${ZPOOLS[@]}"; do
    if replicate_pool "$pool" "$REMOTE_NODE_IP" "$REMOTE_NODE_NAME"; then
        POOLS_SUCCESS=$((POOLS_SUCCESS + 1))
    else
        POOLS_FAILED=$((POOLS_FAILED + 1))
    fi
done

# Résumé final
export CURRENT_POOL="global"
log "info" "=========================================="
log "info" "RÉSUMÉ DE LA RÉPLICATION"
log "info" "=========================================="
log "info" "Pools traités: ${POOLS_TOTAL}"
log "info" "  ✓ Succès: ${POOLS_SUCCESS}"
log "info" "  ✗ Échecs: ${POOLS_FAILED}"
log "info" "=========================================="

if [[ $POOLS_FAILED -eq 0 ]]; then
    log "info" "✓ Toutes les réplications ont réussi"
    send_notification "info" "Réplication ZFS réussie" \
        "Toutes les réplications ZFS ont réussi.

Pools répliqués: ${POOLS_TOTAL}
Succès: ${POOLS_SUCCESS}
Nœud actif: $(hostname)
Nœud distant: ${REMOTE_NODE_NAME}"
    exit 0
else
    log "error" "✗ ${POOLS_FAILED} pool(s) ont échoué"
    send_notification "error" "Échec réplication ZFS" \
        "${POOLS_FAILED} pool(s) ont échoué lors de la réplication.

Total: ${POOLS_TOTAL}
Succès: ${POOLS_SUCCESS}
Échecs: ${POOLS_FAILED}

Vérifier les logs: /var/log/zfs-nfs-replica/"
    exit 1
fi
