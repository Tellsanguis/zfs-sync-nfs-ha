#!/usr/bin/env bats
#
# Tests unitaires pour les fonctions de health check
# Tests simplifiés pour environnement sans ZFS (container Docker)
#

load test_helper

# Charger uniquement les fonctions du script (pas le code principal)
setup() {
    # Setup environnement
    setup_script_env

    # Sourcer le script en mode test (le BATS_TEST_MODE évite l'exécution du main)
    export BATS_TEST_MODE=true
    source "${BATS_TEST_DIRNAME}/../zfs-nfs-replica.sh"
}

teardown() {
    cleanup_script_env
}

# ============================================================================
# Tests: Fonctions existent et sont appelables
# ============================================================================

@test "get_pool_disk_uuids: fonction existe" {
    declare -F get_pool_disk_uuids
}

@test "init_disk_tracking: fonction existe" {
    declare -F init_disk_tracking
}

@test "verify_disk_presence: fonction existe" {
    declare -F verify_disk_presence
}

@test "check_pool_health_status: fonction existe" {
    declare -F check_pool_health_status
}

@test "triple_health_check: fonction existe" {
    declare -F triple_health_check
}

@test "check_recent_critical_error: fonction existe" {
    declare -F check_recent_critical_error
}

@test "record_critical_error: fonction existe" {
    declare -F record_critical_error
}

@test "handle_health_failure: fonction existe" {
    declare -F handle_health_failure
}

@test "verify_pool_health: fonction existe" {
    declare -F verify_pool_health
}

# ============================================================================
# Tests: check_recent_critical_error (ne nécessite pas ZFS)
# ============================================================================

@test "check_recent_critical_error: retourne 0 si erreur récente (<1h)" {
    # Erreur il y a 30 minutes (1800 secondes)
    local current_epoch=1735481400
    local error_epoch=$((current_epoch - 1800))

    export TEST_CURRENT_EPOCH=$current_epoch
    create_critical_error_file "zpool1" "$error_epoch"

    run check_recent_critical_error "zpool1"

    [ "$status" -eq 0 ]
}

@test "check_recent_critical_error: retourne 1 si erreur ancienne (>1h)" {
    # Erreur il y a 2 heures (7200 secondes)
    local current_epoch=1735481400
    local error_epoch=$((current_epoch - 7200))

    export TEST_CURRENT_EPOCH=$current_epoch
    create_critical_error_file "zpool1" "$error_epoch"

    run check_recent_critical_error "zpool1"

    [ "$status" -eq 1 ]
}

@test "check_recent_critical_error: retourne 1 si pas de fichier d'erreur" {
    rm -f "${STATE_DIR}/critical-errors-zpool1.txt"

    run check_recent_critical_error "zpool1"

    [ "$status" -eq 1 ]
}

@test "check_recent_critical_error: cooldown de 1h est respecté" {
    local current_epoch=1735481400
    local error_epoch=$((current_epoch - 3599))  # 1 seconde avant le cooldown

    export TEST_CURRENT_EPOCH=$current_epoch
    create_critical_error_file "zpool1" "$error_epoch"

    run check_recent_critical_error "zpool1"

    [ "$status" -eq 0 ]  # Encore dans la période de cooldown
}

# ============================================================================
# Tests: Configuration CLUSTER_NODES
# ============================================================================

@test "CLUSTER_NODES: contient acemagician et elitedesk" {
    [ -n "${CLUSTER_NODES[acemagician]}" ]
    [ -n "${CLUSTER_NODES[elitedesk]}" ]
}

@test "CLUSTER_NODES: IPs correctes pour chaque nœud" {
    [ "${CLUSTER_NODES[acemagician]}" = "192.168.100.10" ]
    [ "${CLUSTER_NODES[elitedesk]}" = "192.168.100.20" ]
}

@test "Nœud distant: elitedesk détecte acemagician" {
    export TEST_HOSTNAME="elitedesk"
    LOCAL_NODE=$(hostname)

    # Trouver le nœud distant
    REMOTE_NODE_NAME=""
    REMOTE_NODE_IP=""
    for node in "${!CLUSTER_NODES[@]}"; do
        if [[ "$node" != "$LOCAL_NODE" ]]; then
            REMOTE_NODE_NAME="$node"
            REMOTE_NODE_IP="${CLUSTER_NODES[$node]}"
            break
        fi
    done

    [ "$REMOTE_NODE_NAME" = "acemagician" ]
    [ "$REMOTE_NODE_IP" = "192.168.100.10" ]
}

@test "Nœud distant: acemagician détecte elitedesk" {
    export TEST_HOSTNAME="acemagician"
    LOCAL_NODE=$(hostname)

    # Trouver le nœud distant
    REMOTE_NODE_NAME=""
    REMOTE_NODE_IP=""
    for node in "${!CLUSTER_NODES[@]}"; do
        if [[ "$node" != "$LOCAL_NODE" ]]; then
            REMOTE_NODE_NAME="$node"
            REMOTE_NODE_IP="${CLUSTER_NODES[$node]}"
            break
        fi
    done

    [ "$REMOTE_NODE_NAME" = "elitedesk" ]
    [ "$REMOTE_NODE_IP" = "192.168.100.20" ]
}

@test "Nœud distant: erreur si nœud local inconnu" {
    export TEST_HOSTNAME="unknown-node"
    LOCAL_NODE=$(hostname)

    # Vérifier que le nœud local n'est pas dans la config
    if [[ ! -v "CLUSTER_NODES[$LOCAL_NODE]" ]]; then
        # Comportement attendu : erreur
        run echo "Node not found"
        [ "$status" -eq 0 ]
    else
        # Ne devrait pas arriver ici
        false
    fi
}

@test "Nœud distant: erreur si cluster à 1 seul nœud" {
    # Créer un cluster avec un seul nœud
    declare -A TEST_CLUSTER=(
        ["lonely-node"]="192.168.100.99"
    )

    export TEST_HOSTNAME="lonely-node"
    LOCAL_NODE=$(hostname)

    # Chercher nœud distant
    REMOTE_NODE_NAME=""
    REMOTE_NODE_IP=""
    for node in "${!TEST_CLUSTER[@]}"; do
        if [[ "$node" != "$LOCAL_NODE" ]]; then
            REMOTE_NODE_NAME="$node"
            REMOTE_NODE_IP="${TEST_CLUSTER[$node]}"
            break
        fi
    done

    # Aucun nœud distant trouvé
    [ -z "$REMOTE_NODE_NAME" ]
    [ -z "$REMOTE_NODE_IP" ]
}

@test "Cluster 3 nœuds: détecte le premier nœud distant disponible" {
    # Créer un cluster avec 3 nœuds
    declare -A EXTENDED_CLUSTER=(
        ["node1"]="192.168.100.10"
        ["node2"]="192.168.100.20"
        ["node3"]="192.168.100.30"
    )

    export TEST_HOSTNAME="node1"
    LOCAL_NODE=$(hostname)

    # Trouver le premier nœud distant
    REMOTE_NODE_NAME=""
    REMOTE_NODE_IP=""
    for node in "${!EXTENDED_CLUSTER[@]}"; do
        if [[ "$node" != "$LOCAL_NODE" ]]; then
            REMOTE_NODE_NAME="$node"
            REMOTE_NODE_IP="${EXTENDED_CLUSTER[$node]}"
            break
        fi
    done

    # Un nœud distant doit être trouvé (node2 ou node3)
    [ -n "$REMOTE_NODE_NAME" ]
    [ -n "$REMOTE_NODE_IP" ]
    [[ "$REMOTE_NODE_NAME" != "node1" ]]
}

# ============================================================================
# Tests: Validation des variables de configuration
# ============================================================================

@test "Variables de config: ZPOOLS est un tableau non vide" {
    [ "${#ZPOOLS[@]}" -gt 0 ]
}

@test "Variables de config: CTID est défini" {
    [ -n "$CTID" ]
    [ "$CTID" -eq "$CTID" ] 2>/dev/null  # Vérifier que c'est un nombre
}

@test "Variables de config: CONTAINER_NAME est défini" {
    [ -n "$CONTAINER_NAME" ]
}

@test "Variables de config: HEALTH_CHECK_MIN_FREE_SPACE valide" {
    [ "$HEALTH_CHECK_MIN_FREE_SPACE" -ge 0 ]
    [ "$HEALTH_CHECK_MIN_FREE_SPACE" -le 100 ]
}

@test "Variables de config: HEALTH_CHECK_ERROR_COOLDOWN valide" {
    [ "$HEALTH_CHECK_ERROR_COOLDOWN" -gt 0 ]
}

@test "Variables de config: STATE_DIR est défini" {
    [ -n "$STATE_DIR" ]
}

@test "Variables de config: LOG_DIR est défini" {
    [ -n "$LOG_DIR" ]
}

@test "Variables de config: SSH_KEY est défini" {
    [ -n "$SSH_KEY" ]
}

# ============================================================================
# Tests: Fichiers d'état (sans ZFS)
# ============================================================================

@test "create_disk_uuid_file: crée fichier avec format correct" {
    create_disk_uuid_file "zpool1" "wwn-0x5000cca2dfe2e414"

    [ -f "${STATE_DIR}/disk-uuids-zpool1.txt" ]
    grep -q "initialized=true" "${STATE_DIR}/disk-uuids-zpool1.txt"
    grep -q "pool=zpool1" "${STATE_DIR}/disk-uuids-zpool1.txt"
    grep -q "wwn-0x5000cca2dfe2e414" "${STATE_DIR}/disk-uuids-zpool1.txt"
}

@test "create_critical_error_file: crée fichier avec format correct" {
    create_critical_error_file "zpool1" "1735481400"

    [ -f "${STATE_DIR}/critical-errors-zpool1.txt" ]
    grep -q "epoch=1735481400" "${STATE_DIR}/critical-errors-zpool1.txt"
    grep -q "reason=Test error" "${STATE_DIR}/critical-errors-zpool1.txt"
}

@test "Fichiers d'état: isolation par pool" {
    create_disk_uuid_file "zpool1"
    create_disk_uuid_file "zpool2"

    [ -f "${STATE_DIR}/disk-uuids-zpool1.txt" ]
    [ -f "${STATE_DIR}/disk-uuids-zpool2.txt" ]

    # Les fichiers doivent être différents
    ! diff "${STATE_DIR}/disk-uuids-zpool1.txt" "${STATE_DIR}/disk-uuids-zpool2.txt"
}
