#!/bin/bash
#
# Helpers et mocks pour les tests BATS
# Ce fichier fournit des simulations de toutes les commandes système
# utilisées par zfs-nfs-replica.sh, permettant de tester sans ZFS réel
#

# Variables globales pour les tests
export TEST_FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures"
export TEST_POOL_STATE="${TEST_POOL_STATE:-ONLINE}"
export TEST_POOL_CAPACITY="${TEST_POOL_CAPACITY:-67}"
export TEST_LXC_STATUS="${TEST_LXC_STATUS:-running}"
export TEST_DISK_PRESENT="${TEST_DISK_PRESENT:-true}"

# Mock: zpool - Simuler les commandes ZFS pool
zpool() {
    case "$1" in
        status)
            if [[ "$2" == "-P" ]]; then
                # Format détaillé avec chemins physiques
                if [[ "$TEST_POOL_STATE" == "ONLINE" ]]; then
                    cat "${TEST_FIXTURES_DIR}/zpool_status_healthy.txt"
                else
                    cat "${TEST_FIXTURES_DIR}/zpool_status_degraded.txt"
                fi
            else
                # Format simple
                echo "zpool1  ${TEST_POOL_STATE}  -  -  -"
            fi
            ;;
        list)
            local format="${4:-name,health}"
            if [[ "$3" == "-o" ]]; then
                case "$4" in
                    health)
                        echo "${TEST_POOL_STATE}"
                        ;;
                    capacity)
                        echo "${TEST_POOL_CAPACITY}%"
                        ;;
                    *)
                        echo "zpool1"
                        ;;
                esac
            else
                echo "zpool1  7.67T  5.12T  2.55T  ${TEST_POOL_CAPACITY}%  ${TEST_POOL_STATE}  -"
            fi
            ;;
        import)
            echo "pool zpool1 imported"
            return 0
            ;;
        *)
            echo "Mock zpool: commande non supportée: $*" >&2
            return 1
            ;;
    esac
}

# Mock: zfs - Simuler les commandes ZFS dataset
zfs() {
    case "$1" in
        list)
            if [[ "$2" == "-t" && "$3" == "snapshot" ]]; then
                cat "${TEST_FIXTURES_DIR}/zfs_list_snapshots.txt"
            else
                cat "${TEST_FIXTURES_DIR}/zfs_list_snapshots.txt"
            fi
            ;;
        get)
            echo "5120000000000"  # 5.12TB en bytes
            ;;
        *)
            echo "Mock zfs: commande non supportée: $*" >&2
            return 0
            ;;
    esac
}

# Mock: pct - Simuler les commandes Proxmox LXC
pct() {
    case "$1" in
        status)
            echo "status: ${TEST_LXC_STATUS}"
            ;;
        exec)
            # Simuler une exécution réussie dans le container
            return 0
            ;;
        stop)
            echo "Stopping CT ${2}"
            TEST_LXC_STATUS="stopped"
            return 0
            ;;
        start)
            echo "Starting CT ${2}"
            TEST_LXC_STATUS="running"
            return 0
            ;;
        *)
            echo "Mock pct: commande non supportée: $*" >&2
            return 1
            ;;
    esac
}

# Mock: ha-manager - Simuler Proxmox HA manager
ha-manager() {
    case "$1" in
        migrate)
            echo "Migrating ${2} to ${3}"
            return 0
            ;;
        status)
            echo "ct:103 started elitedesk"
            return 0
            ;;
        *)
            echo "Mock ha-manager: commande non supportée: $*" >&2
            return 1
            ;;
    esac
}

# Mock: ssh - Simuler les connexions SSH
ssh() {
    # Ignorer les options SSH (-i, -o, etc.)
    local cmd=""
    for arg in "$@"; do
        if [[ ! "$arg" =~ ^- ]] && [[ "$arg" != *"@"* ]] && [[ "$arg" != "root" ]]; then
            cmd="$arg"
            break
        fi
    done

    if [[ "$cmd" == "echo OK" ]] || [[ "$cmd" == *"echo"* ]]; then
        echo "OK"
        return 0
    fi

    # Simuler les commandes distantes
    eval "$cmd"
}

# Mock: syncoid - Simuler la réplication Syncoid
syncoid() {
    echo "Sending incremental zpool1@autosnap_2024-12-29_14:30:00"
    echo "2.15GB 0:00:45 [48.9MB/s]"
    return 0
}

# Mock: logger - Simuler syslog
logger() {
    # Silencieux pour les tests, sauf si DEBUG
    if [[ "${BATS_TEST_DEBUG:-}" == "true" ]]; then
        echo "[SYSLOG] $*" >&2
    fi
}

# Mock: hostname - Retourner un hostname de test
hostname() {
    echo "${TEST_HOSTNAME:-elitedesk}"
}

# Mock: readlink - Simuler la résolution de symlinks
readlink() {
    if [[ "$1" == "-f" ]]; then
        # Retourner un chemin /dev/sdX simulé
        echo "/dev/sda1"
    else
        echo "/dev/disk/by-id/wwn-0x5000cca2dfe2e414"
    fi
}

# Mock: ls pour /dev/disk/by-id/
ls() {
    if [[ "$*" =~ /dev/disk/by-id ]]; then
        if [[ "$TEST_DISK_PRESENT" == "true" ]]; then
            echo "lrwxrwxrwx 1 root root 9 Dec 29 14:00 wwn-0x5000cca2dfe2e414 -> ../../sda1"
        fi
        return 0
    fi

    # Appeler le vrai ls pour autres cas
    command ls "$@"
}

# Mock: date - Contrôler le temps dans les tests
date() {
    if [[ "$1" == "+%s" ]]; then
        echo "${TEST_CURRENT_EPOCH:-1735481400}"
    elif [[ "$1" == "+%Y-%m-%d_%H:%M:%S" ]]; then
        echo "2024-12-29_14:30:00"
    else
        command date "$@"
    fi
}

# Helper: Setup des variables d'environnement pour le script
setup_script_env() {
    export ZPOOLS=("zpool1")
    export CTID=103
    export CONTAINER_NAME="nfs-server"
    export STATE_DIR="${BATS_TMPDIR}/zfs-nfs-replica"
    export LOG_DIR="${BATS_TMPDIR}/logs"
    export HEALTH_CHECK_MIN_FREE_SPACE=5
    export HEALTH_CHECK_ERROR_COOLDOWN=3600
    export NOTIFICATION_ENABLED=false
    export AUTO_UPDATE_ENABLED=false
    export CHECK_DELAY=0  # Pas de délai dans les tests

    # Cluster nodes
    declare -gA CLUSTER_NODES=(
        ["acemagician"]="192.168.100.10"
        ["elitedesk"]="192.168.100.20"
    )

    # Créer les répertoires nécessaires
    mkdir -p "$STATE_DIR"
    mkdir -p "$LOG_DIR"
}

# Helper: Nettoyer l'environnement de test
cleanup_script_env() {
    rm -rf "${BATS_TMPDIR}/zfs-nfs-replica"
    rm -rf "${BATS_TMPDIR}/logs"
}

# Helper: Créer un fichier d'état disk-uuids
create_disk_uuid_file() {
    local pool="$1"
    local uuid="${2:-wwn-0x5000cca2dfe2e414}"

    mkdir -p "${STATE_DIR}"
    cat > "${STATE_DIR}/disk-uuids-${pool}.txt" <<EOF
initialized=true
timestamp=2024-12-29_14:00:00
hostname=elitedesk
pool=${pool}
# Physical disk UUIDs
${uuid}
EOF
}

# Helper: Créer un fichier d'erreur critique
create_critical_error_file() {
    local pool="$1"
    local epoch="${2:-${TEST_CURRENT_EPOCH:-1735481400}}"

    mkdir -p "${STATE_DIR}"
    cat > "${STATE_DIR}/critical-errors-${pool}.txt" <<EOF
timestamp=2024-12-29_14:00:00
epoch=${epoch}
reason=Test error
action=lxc_migrated
target_node=acemagician
EOF
}

# Exporter tous les mocks
export -f zpool zfs pct ha-manager ssh syncoid logger hostname readlink ls date
export -f setup_script_env cleanup_script_env
export -f create_disk_uuid_file create_critical_error_file
