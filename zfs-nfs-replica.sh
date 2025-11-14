#!/bin/bash
#
# Script de réplication ZFS automatique pour NFS HA
# À déployer sur acemagician et elitedesk
#
# Ce script :
# - Vérifie 3 fois que le LXC nfs-server est actif localement
# - Détermine le nœud distant automatiquement
# - Réplique le dataset ZFS vers le nœud passif
# - Utilise un verrou pour éviter les réplications concurrentes
# - Gère l'activation/désactivation de Sanoid selon le nœud actif
#
# Auteur : BENE Maël
# Version : 1.3
#

set -euo pipefail

# Configuration
CTID=103
CONTAINER_NAME="nfs-server"
ZPOOL="zpool1"  # Pool entier à répliquer (tous les datasets)
CHECK_DELAY=2  # Délai entre chaque vérification (secondes)
LOG_FACILITY="local0"
SSH_KEY="/root/.ssh/id_ed25519_zfs_replication"
STATE_DIR="/var/lib/zfs-nfs-replica"
SIZES_FILE="${STATE_DIR}/last-sync-sizes.txt"
SIZE_TOLERANCE=20  # Tolérance de variation en pourcentage (±20%)
MIN_REMOTE_RATIO=50  # Le distant doit avoir au moins 50% de la taille du local

# Fonction de logging
log() {
    local level="$1"
    shift
    logger -t "zfs-nfs-replica" -p "${LOG_FACILITY}.${level}" "$@"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $@" >&2
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

# Gestion de Sanoid selon le nœud actif
manage_sanoid() {
    local action="$1"  # "enable" ou "disable"

    if [[ "$action" == "enable" ]]; then
        # Activer Sanoid sur le nœud actif
        if systemctl is-enabled sanoid.timer &>/dev/null; then
            if ! systemctl is-active sanoid.timer &>/dev/null; then
                log "info" "Activation de Sanoid sur le nœud actif"
                systemctl start sanoid.timer
            fi
        else
            log "info" "Activation et démarrage de Sanoid sur le nœud actif"
            systemctl enable --now sanoid.timer
        fi
    elif [[ "$action" == "disable" ]]; then
        # Désactiver Sanoid sur le nœud passif
        if systemctl is-active sanoid.timer &>/dev/null; then
            log "info" "Désactivation de Sanoid sur le nœud passif"
            systemctl stop sanoid.timer
        fi
        if systemctl is-enabled sanoid.timer &>/dev/null; then
            log "info" "Désactivation permanente de Sanoid sur le nœud passif"
            systemctl disable sanoid.timer
        fi
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

    log "info" "Sauvegarde des tailles de datasets dans ${SIZES_FILE}"

    # Créer le répertoire si nécessaire
    mkdir -p "$STATE_DIR"

    # Sauvegarder avec timestamp
    {
        echo "timestamp=$(date '+%Y-%m-%d_%H:%M:%S')"
        get_dataset_sizes "local" "$pool" | awk '{print $1"="$2}'
    } > "$SIZES_FILE"

    log "info" "✓ Tailles sauvegardées"
}

# Vérification de sécurité des tailles avant --force-delete
check_size_safety() {
    local remote_ip="$1"
    local pool="$2"

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
    if [[ -f "$SIZES_FILE" ]]; then
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
        previous_timestamp=$(grep "^timestamp=" "$SIZES_FILE" | cut -d= -f2)
        log "info" "Dernière synchronisation réussie: ${previous_timestamp}"

        local dataset size_remote size_previous diff_percent
        while IFS=$'\t' read -r dataset size_remote; do
            # Récupérer la taille précédente
            size_previous=$(grep "^${dataset}=" "$SIZES_FILE" | cut -d= -f2)

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

# Détermination du nœud local et distant
LOCAL_NODE=$(hostname)
log "info" "Démarrage du script sur le nœud: ${LOCAL_NODE}"

# Déterminer le nœud distant et son IP
case "$LOCAL_NODE" in
    "acemagician")
        REMOTE_NODE_NAME="elitedesk"
        REMOTE_NODE_IP="192.168.100.20"
        ;;
    "elitedesk")
        REMOTE_NODE_NAME="acemagician"
        REMOTE_NODE_IP="192.168.100.10"
        ;;
    *)
        log "error" "Nœud inconnu: ${LOCAL_NODE}. Ce script doit s'exécuter sur acemagician ou elitedesk."
        exit 1
        ;;
esac

log "info" "Nœud distant configuré: ${REMOTE_NODE_NAME} (${REMOTE_NODE_IP})"

# Triple vérification de sécurité
if ! verify_lxc_is_active; then
    log "info" "Le LXC ${CTID} n'est pas actif sur ce nœud. Pas de réplication nécessaire."
    # Désactiver Sanoid sur le nœud passif
    manage_sanoid "disable"
    exit 0
fi

# Le LXC est actif ici : activer Sanoid sur ce nœud
manage_sanoid "enable"

# Vérification de l'existence du pool
if ! zpool list "$ZPOOL" &>/dev/null; then
    log "error" "Le pool ${ZPOOL} n'existe pas sur ce nœud"
    exit 1
fi

# Verrou pour éviter les réplications concurrentes
LOCKFILE="/var/run/zfs-replica-${ZPOOL}.lock"
LOCKFD=200

# Fonction de nettoyage
cleanup() {
    if [[ -n "${LOCK_ACQUIRED:-}" ]]; then
        log "info" "Libération du verrou"
        flock -u $LOCKFD
    fi
}
trap cleanup EXIT

# Tentative d'acquisition du verrou (non-bloquant)
eval "exec $LOCKFD>$LOCKFILE"
if ! flock -n $LOCKFD; then
    log "info" "Une réplication est déjà en cours. Abandon."
    exit 0
fi
LOCK_ACQUIRED=1

log "info" "Verrou acquis. Début de la réplication."

# Vérification de la connectivité SSH vers le nœud distant
if ! ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o BatchMode=yes "root@${REMOTE_NODE_IP}" "echo OK" &>/dev/null; then
    log "error" "Impossible de se connecter à ${REMOTE_NODE_NAME} (${REMOTE_NODE_IP}) via SSH"
    exit 1
fi

log "info" "Connexion SSH vers ${REMOTE_NODE_NAME} (${REMOTE_NODE_IP}) vérifiée"

# Vérification que le pool existe sur le nœud distant
if ! ssh -i "$SSH_KEY" "root@${REMOTE_NODE_IP}" "zpool list ${ZPOOL}" &>/dev/null; then
    log "error" "Le pool ${ZPOOL} n'existe pas sur ${REMOTE_NODE_NAME}"
    exit 1
fi

# Vérification des snapshots en commun et choix de la stratégie de réplication
log "info" "Début de la réplication récursive: ${ZPOOL} → ${REMOTE_NODE_NAME} (${REMOTE_NODE_IP}):${ZPOOL}"

# Syncoid utilise les options SSH via la variable d'environnement SSH
export SSH="ssh -i ${SSH_KEY}"

# Déterminer si c'est une première synchronisation
if check_common_snapshots "$REMOTE_NODE_IP" "$ZPOOL"; then
    # Snapshots en commun : réplication incrémentale normale
    log "info" "Mode: Réplication incrémentale (snapshots en commun détectés)"
    SYNCOID_OPTS="--recursive --no-sync-snap --quiet"
else
    # Pas de snapshots en commun : première synchronisation avec --force-delete
    log "warning" "Mode: Première synchronisation détectée"
    log "warning" "Utilisation de --force-delete pour écraser les datasets incompatibles"

    # SÉCURITÉ : Vérifier les tailles avant d'autoriser --force-delete
    if ! check_size_safety "$REMOTE_NODE_IP" "$ZPOOL"; then
        log "error" "╔════════════════════════════════════════════════════════════════╗"
        log "error" "║ ARRÊT DE SÉCURITÉ                                              ║"
        log "error" "║ Les vérifications de sécurité ont échoué.                     ║"
        log "error" "║ --force-delete REFUSÉ pour éviter une perte de données.       ║"
        log "error" "║                                                                ║"
        log "error" "║ Actions possibles :                                            ║"
        log "error" "║ 1. Vérifier manuellement les tailles des datasets             ║"
        log "error" "║ 2. Si changement de disque : supprimer ${SIZES_FILE}          ║"
        log "error" "║ 3. Vérifier que le bon nœud est actif (LXC sur le bon nœud)   ║"
        log "error" "╚════════════════════════════════════════════════════════════════╝"
        exit 1
    fi

    log "info" "Note: Première synchronisation - syncoid va créer un snapshot initial"
    log "info" "      Les blocs de données existants seront réutilisés (pas de transfert complet)"
    # Pour la première sync: pas de --no-sync-snap (on veut que syncoid crée un snapshot)
    # mais on garde --force-delete pour écraser les datasets vides/incompatibles
    SYNCOID_OPTS="--recursive --force-delete --quiet"
fi

# Lancer la réplication avec les options appropriées
if syncoid $SYNCOID_OPTS "$ZPOOL" "root@${REMOTE_NODE_IP}:$ZPOOL"; then
    log "info" "✓ Réplication récursive réussie vers ${REMOTE_NODE_NAME} (${REMOTE_NODE_IP})"
    log "info" "  Tous les datasets de ${ZPOOL} ont été synchronisés"

    # Sauvegarder les tailles après sync réussie
    save_dataset_sizes "$ZPOOL"

    exit 0
else
    log "error" "✗ Échec de la réplication vers ${REMOTE_NODE_NAME} (${REMOTE_NODE_IP})"
    exit 1
fi
