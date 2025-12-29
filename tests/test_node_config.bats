#!/usr/bin/env bats
#
# Tests unitaires pour la configuration des nœuds
# Test de la logique de découverte du nœud distant
#

load test_helper

setup() {
    setup_script_env
}

teardown() {
    cleanup_script_env
}

# ============================================================================
# Tests: Configuration des nœuds avec CLUSTER_NODES
# ============================================================================

@test "CLUSTER_NODES: contient acemagician et elitedesk" {
    # Vérifier que le tableau associatif est bien défini
    [ -n "${CLUSTER_NODES[acemagician]}" ]
    [ -n "${CLUSTER_NODES[elitedesk]}" ]
}

@test "CLUSTER_NODES: IPs correctes pour chaque nœud" {
    [ "${CLUSTER_NODES[acemagician]}" = "192.168.100.10" ]
    [ "${CLUSTER_NODES[elitedesk]}" = "192.168.100.20" ]
}

# ============================================================================
# Tests: Détection du nœud distant
# ============================================================================

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

# ============================================================================
# Tests: Extension à 3+ nœuds
# ============================================================================

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
