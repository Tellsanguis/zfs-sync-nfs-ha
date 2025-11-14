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
# Version : 1.1
#

set -euo pipefail

# Configuration
CTID=103
CONTAINER_NAME="nfs-server"
ZPOOL="zpool1"  # Pool entier à répliquer (tous les datasets)
CHECK_DELAY=2  # Délai entre chaque vérification (secondes)
LOG_FACILITY="local0"
SSH_KEY="/root/.ssh/id_ed25519_zfs_replication"

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

# Réplication avec syncoid (récursive pour tous les datasets)
log "info" "Début de la réplication récursive: ${ZPOOL} → ${REMOTE_NODE_NAME} (${REMOTE_NODE_IP}):${ZPOOL}"

# Syncoid utilise les options SSH via la variable d'environnement SSH
export SSH="ssh -i ${SSH_KEY}"

if syncoid --recursive --no-sync-snap --quiet "$ZPOOL" "root@${REMOTE_NODE_IP}:$ZPOOL"; then
    log "info" "✓ Réplication récursive réussie vers ${REMOTE_NODE_NAME} (${REMOTE_NODE_IP})"
    log "info" "  Tous les datasets de ${ZPOOL} ont été synchronisés"
    exit 0
else
    log "error" "✗ Échec de la réplication vers ${REMOTE_NODE_NAME} (${REMOTE_NODE_IP})"
    exit 1
fi
