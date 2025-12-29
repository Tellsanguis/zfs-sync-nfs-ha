#!/usr/bin/env bats
#
# Tests unitaires pour les fonctions de health check
# Test des vérifications de santé des disques et pools ZFS
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
# Tests: get_pool_disk_uuids()
# ============================================================================

@test "get_pool_disk_uuids: retourne des UUIDs pour un pool sain" {
    run get_pool_disk_uuids "zpool1"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "wwn-0x5000cca2dfe2e414" ]]
}

@test "get_pool_disk_uuids: retourne vide pour pool inexistant" {
    # Mock zpool pour retourner une erreur
    zpool() {
        if [[ "$1" == "status" ]]; then
            echo "cannot open 'fakerpool': no such pool" >&2
            return 1
        fi
    }
    export -f zpool

    run get_pool_disk_uuids "fakerpool"

    # La fonction doit gérer l'erreur gracieusement
    [ "$status" -ne 0 ] || [ -z "$output" ]
}

# ============================================================================
# Tests: init_disk_tracking()
# ============================================================================

@test "init_disk_tracking: crée le fichier d'état avec UUIDs" {
    run init_disk_tracking "zpool1"

    [ "$status" -eq 0 ]
    [ -f "${STATE_DIR}/disk-uuids-zpool1.txt" ]

    # Vérifier le contenu
    grep -q "initialized=true" "${STATE_DIR}/disk-uuids-zpool1.txt"
    grep -q "pool=zpool1" "${STATE_DIR}/disk-uuids-zpool1.txt"
    grep -q "wwn-0x" "${STATE_DIR}/disk-uuids-zpool1.txt"
}

@test "init_disk_tracking: ne réinitialise pas si déjà initialisé" {
    # Créer un fichier déjà initialisé
    create_disk_uuid_file "zpool1"

    # Modifier le timestamp pour vérifier qu'il ne change pas
    original_content=$(cat "${STATE_DIR}/disk-uuids-zpool1.txt")

    run init_disk_tracking "zpool1"

    [ "$status" -eq 0 ]

    # Le fichier ne doit pas avoir changé
    new_content=$(cat "${STATE_DIR}/disk-uuids-zpool1.txt")
    [ "$original_content" == "$new_content" ]
}

# ============================================================================
# Tests: verify_disk_presence()
# ============================================================================

@test "verify_disk_presence: succès si tous les disques présents" {
    create_disk_uuid_file "zpool1" "wwn-0x5000cca2dfe2e414"
    export TEST_DISK_PRESENT=true

    run verify_disk_presence "zpool1"

    [ "$status" -eq 0 ]
}

@test "verify_disk_presence: échec si disque manquant" {
    # Créer un fichier avec UUID fictif
    create_disk_uuid_file "zpool1" "wwn-0xFAKE_MISSING_DISK"
    export TEST_DISK_PRESENT=false

    run verify_disk_presence "zpool1"

    [ "$status" -eq 1 ]
    [[ "$output" =~ "manquant" ]] || [[ "$output" =~ "MISSING" ]]
}

@test "verify_disk_presence: retourne erreur si fichier d'état absent" {
    # Pas de fichier disk-uuids
    rm -f "${STATE_DIR}/disk-uuids-zpool1.txt"

    run verify_disk_presence "zpool1"

    [ "$status" -eq 1 ]
}

# ============================================================================
# Tests: check_pool_health_status()
# ============================================================================

@test "check_pool_health_status: succès pour pool ONLINE avec espace libre" {
    export TEST_POOL_STATE="ONLINE"
    export TEST_POOL_CAPACITY=67

    run check_pool_health_status "zpool1"

    [ "$status" -eq 0 ]
}

@test "check_pool_health_status: échec pour pool DEGRADED" {
    export TEST_POOL_STATE="DEGRADED"
    export TEST_POOL_CAPACITY=67

    run check_pool_health_status "zpool1"

    [ "$status" -eq 1 ]
}

@test "check_pool_health_status: échec si espace disque critique (>95%)" {
    export TEST_POOL_STATE="ONLINE"
    export TEST_POOL_CAPACITY=96

    run check_pool_health_status "zpool1"

    [ "$status" -eq 1 ]
    [[ "$output" =~ "espace libre" ]] || [[ "$output" =~ "capacity" ]]
}

@test "check_pool_health_status: succès avec exactement 95% (limite)" {
    export TEST_POOL_STATE="ONLINE"
    export TEST_POOL_CAPACITY=95

    run check_pool_health_status "zpool1"

    # 95% = 5% libre, c'est la limite, doit passer
    [ "$status" -eq 0 ]
}

# ============================================================================
# Tests: triple_health_check()
# ============================================================================

@test "triple_health_check: succès si 3/3 tentatives réussissent" {
    create_disk_uuid_file "zpool1"
    export TEST_POOL_STATE="ONLINE"
    export TEST_POOL_CAPACITY=67
    export TEST_DISK_PRESENT=true
    export CHECK_DELAY=0  # Pas de délai dans tests

    run triple_health_check "zpool1"

    [ "$status" -eq 0 ]
}

@test "triple_health_check: échec si les 3 tentatives échouent" {
    create_disk_uuid_file "zpool1" "wwn-0xFAKE_MISSING"
    export TEST_DISK_PRESENT=false
    export CHECK_DELAY=0

    run triple_health_check "zpool1"

    [ "$status" -eq 1 ]
}

@test "triple_health_check: fait vraiment 3 tentatives (pas d'early return)" {
    create_disk_uuid_file "zpool1"
    export TEST_POOL_STATE="DEGRADED"
    export TEST_DISK_PRESENT=true
    export CHECK_DELAY=0

    run triple_health_check "zpool1"

    [ "$status" -eq 1 ]

    # Vérifier qu'il y a bien 3 lignes d'erreur (3 tentatives)
    attempt_count=$(echo "$output" | grep -c "Vérification santé #" || echo "0")
    [ "$attempt_count" -eq 3 ]
}

# ============================================================================
# Tests: check_recent_critical_error()
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

# ============================================================================
# Tests: record_critical_error()
# ============================================================================

@test "record_critical_error: crée fichier avec toutes les infos" {
    run record_critical_error "zpool1" "Test failure reason" "lxc_migrated"

    [ "$status" -eq 0 ]
    [ -f "${STATE_DIR}/critical-errors-zpool1.txt" ]

    grep -q "reason=Test failure reason" "${STATE_DIR}/critical-errors-zpool1.txt"
    grep -q "action=lxc_migrated" "${STATE_DIR}/critical-errors-zpool1.txt"
    grep -q "epoch=" "${STATE_DIR}/critical-errors-zpool1.txt"
}

@test "record_critical_error: écrase le fichier précédent" {
    # Créer une première erreur
    create_critical_error_file "zpool1" "1735400000"

    # Enregistrer une nouvelle erreur
    run record_critical_error "zpool1" "New error" "lxc_stopped"

    [ "$status" -eq 0 ]

    # Vérifier que c'est la nouvelle erreur
    grep -q "reason=New error" "${STATE_DIR}/critical-errors-zpool1.txt"
    grep -q "action=lxc_stopped" "${STATE_DIR}/critical-errors-zpool1.txt"
}

# ============================================================================
# Tests: handle_health_failure()
# ============================================================================

@test "handle_health_failure: migre le LXC si première erreur" {
    # Pas d'erreur récente
    rm -f "${STATE_DIR}/critical-errors-zpool1.txt"

    export REMOTE_NODE_NAME="acemagician"

    run handle_health_failure "zpool1" "Disk failure"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "MIGRATION" ]] || [[ "$output" =~ "migrate" ]]

    # Vérifier que l'erreur a été enregistrée
    [ -f "${STATE_DIR}/critical-errors-zpool1.txt" ]
    grep -q "action=lxc_migrated" "${STATE_DIR}/critical-errors-zpool1.txt"
}

@test "handle_health_failure: arrête le LXC si erreur récente (<1h)" {
    # Erreur récente (30 min)
    local current_epoch=1735481400
    local error_epoch=$((current_epoch - 1800))

    export TEST_CURRENT_EPOCH=$current_epoch
    create_critical_error_file "zpool1" "$error_epoch"

    run handle_health_failure "zpool1" "Another disk failure"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "ARRÊT" ]] || [[ "$output" =~ "stop" ]] || [[ "$output" =~ "ping-pong" ]]

    # Vérifier que l'erreur a été mise à jour
    grep -q "action=lxc_stopped" "${STATE_DIR}/critical-errors-zpool1.txt"
}
