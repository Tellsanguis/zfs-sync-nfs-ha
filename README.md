# Réplication Bidirectionnelle ZFS avec Serveur NFS Hautement Disponible

Une implémentation prête pour la production d'un stockage NFS hautement disponible utilisant Proxmox HA, ZFS, et Sanoid/Syncoid pour la réplication bidirectionnelle automatique.

## Contexte du Projet

Ce projet répond au défi de créer une solution de stockage redondante et hautement disponible en utilisant des pools ZFS indépendants sur du matériel standard, spécifiquement conçue pour du stockage de données froides avec des disques durs 3.5" connectés en USB.

### Le Défi

- **Contraintes matérielles** : Deux disques durs SATA 3.5" dans des boîtiers USB, sur des nœuds physiques différents
- **Caractéristiques des données** : Stockage froid (fichiers média, archives) avec écritures peu fréquentes et lectures importantes
- **Besoins de disponibilité** : Nécessité d'un basculement automatique avec un temps d'arrêt minimal
- **Infrastructure** : Cluster Proxmox HA existant avec plusieurs nœuds

### La Solution

Les disques étant connectés en USB sur des nœuds physiques séparés, les solutions classiques (miroir ZFS local, DRBD bloc par bloc, ou systèmes de fichiers distribués lourds comme Ceph/GlusterFS) sont soit impossibles, soit disproportionnées pour ce cas d'usage.

Cette architecture implémente une approche plus simple et efficace :

1. **Pools ZFS indépendants** sur des nœuds Proxmox séparés (un disque par nœud)
2. **Réplication bidirectionnelle au niveau ZFS** utilisant Sanoid/Syncoid avec détection automatique de la direction
3. **Modèle actif-passif** où le nœud hébergeant le conteneur LXC NFS devient le maître de réplication
4. **Basculement automatique** exploitant Proxmox HA pour une migration transparente

Cette approche fournit une redondance adaptée aux données froides tout en restant simple à maintenir et optimisée pour du stockage USB.

## Vue d'Ensemble de l'Architecture

### Topologie du Cluster

```
┌─────────────────────────────────────────────────────────────┐
│                    Cluster Proxmox HA                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────────┐              ┌──────────────────┐   │
│  │   acemagician    │              │    elitedesk     │   │
│  │  (192.168.100.10)│◄────────────►│ (192.168.100.20) │   │
│  │                  │  Réplication │                  │   │
│  │  ┌────────────┐  │              │  ┌────────────┐  │   │
│  │  │   zpool1   │  │   Syncoid    │  │   zpool1   │  │   │
│  │  │ (HDD USB)  │  │              │  │ (HDD USB)  │  │   │
│  │  └────────────┘  │              │  └────────────┘  │   │
│  │                  │              │                  │   │
│  │                  │              │  ┌────────────┐  │   │
│  │                  │              │  │  LXC 103   │  │   │
│  │                  │              │  │ NFS Server │  │   │
│  │                  │              │  └────────────┘  │   │
│  └──────────────────┘              └──────────────────┘   │
│                                                             │
│         ┌──────────────────┐                               │
│         │    thinkpad      │                               │
│         │ (192.168.100.30) │                               │
│         │  Nœud témoin     │                               │
│         └──────────────────┘                               │
└─────────────────────────────────────────────────────────────┘
```

### Composants Clés

- **Cluster Proxmox HA** : 2 nœuds de production + 1 nœud témoin pour le quorum
- **Pools ZFS indépendants** : `zpool1` sur chaque nœud de production (un seul HDD 3.5" connecté en USB)
- **Conteneur LXC (CTID 103)** : Serveur NFS avec rootfs sur LINSTOR/DRBD pour le basculement HA
- **Sanoid** : Gestion automatisée des snapshots avec politiques de rétention configurables
- **Syncoid** : Réplication ZFS efficace avec support de reprise
- **Automatisation Systemd** : Exécution basée sur un timer toutes les 10 minutes

### Pourquoi Cette Architecture ?

**Contraintes de Déploiement** :
- Les disques sont connectés en USB sur des nœuds physiques distincts, empêchant un miroir ZFS local (qui nécessite les disques sur le même nœud)
- Les solutions de stockage distribué (Ceph, GlusterFS) sont surdimensionnées pour ce cas d'usage et consomment trop de ressources
- DRBD réplique au niveau bloc, moins efficace que la réplication ZFS incrémentale basée sur les snapshots
- La réplication ZFS via Syncoid offre le meilleur compromis simplicité/efficacité

**Optimisation pour Données Froides** :
- Les fichiers média et archives ont des schémas de lecture élevée / écriture faible
- Un intervalle de réplication de 10 minutes est acceptable (faibles exigences RPO)
- La réplication asynchrone n'impacte pas les performances de lecture
- La bande passante USB 3.0 est suffisante pour les transferts delta de réplication incrémentale

**Rentabilité** :
- Réutilise des disques durs 3.5" existants dans des boîtiers externes
- Pas besoin de contrôleurs SAS coûteux ou de baies hot-swap
- Solution légère comparée aux systèmes de fichiers distribués complexes

## Fonctionnement

### Réplication Actif-Passif

1. **Détection du maître** : Le script de réplication (`zfs-nfs-replica.sh`) effectue une triple vérification de sécurité pour confirmer que le conteneur LXC NFS fonctionne localement
2. **Direction automatique** : Le nœud hébergeant le conteneur actif devient le maître de réplication et pousse les snapshots vers le nœud passif
3. **Réplication complète du pool** : Tous les datasets sous `zpool1` sont répliqués récursivement en utilisant `syncoid --recursive`
4. **Adaptation au basculement** : Lorsque Proxmox HA migre le LXC, la direction de réplication s'inverse automatiquement

### Triple Vérification de Sécurité

Avant d'initier la réplication, le script vérifie trois fois (avec des délais de 2 secondes) :
- Le conteneur existe (`pct status 103`)
- Le statut du conteneur est "running"
- Le conteneur est réactif (test de santé `pct exec`)

Cela évite les scénarios de split-brain et garantit que seul le nœud actif réplique.

### Gestion des Snapshots

Sanoid crée des snapshots selon un calendrier défini :
- **Horaire** : 24 snapshots (rétention de 1 jour)
- **Quotidien** : 7 snapshots (rétention de 1 semaine)
- **Mensuel** : 3 snapshots (rétention de 3 mois)
- **Annuel** : 1 snapshot (rétention de 1 an)

**Configuration dynamique selon le rôle** (conforme à la [documentation Sanoid](https://github.com/jimsalterjrs/sanoid/wiki/Syncoid#snapshot-management-with-sanoid)) :

Le script configure automatiquement Sanoid différemment selon le rôle du nœud :

**Nœud actif** (héberge le LXC) :
- `autosnap = yes` : crée les snapshots
- `autoprune = yes` : supprime les anciens snapshots selon la politique de rétention
- Sanoid.timer activé

**Nœud passif** (reçoit la réplication) :
- `autosnap = no` : ne crée pas de snapshots (ils arrivent via syncoid)
- `autoprune = yes` : supprime les anciens snapshots selon la même politique
- Sanoid.timer activé

Cette approche garantit que les deux nœuds convergent vers le même ensemble de snapshots, évitant l'accumulation indéfinie sur le nœud passif tout en maintenant la synchronisation.

### Détection Automatique de Première Synchronisation

Le script détecte automatiquement s'il s'agit d'une première synchronisation ou d'une réplication incrémentale :

**Réplication incrémentale** (snapshots en commun détectés) :
- Utilise les snapshots existants pour une synchronisation efficace
- Transfert uniquement des deltas (modifications depuis le dernier snapshot)
- Rapide et économe en bande passante

**Première synchronisation** (aucun snapshot en commun) :
- Active automatiquement le mode `--force-delete` de syncoid
- Déclenche les vérifications de sécurité avancées avant toute opération
- Réutilise les blocs de données existants pour éviter un transfert complet

### Protections Anti-Écrasement

Le script intègre un système de sécurité à deux niveaux pour éviter la perte de données lors d'une première synchronisation :

**Protection 1 : Comparaison source/destination**
- Vérifie que les tailles des datasets sont cohérentes entre les nœuds
- Refuse la synchronisation si la source est significativement plus petite que la destination (ratio < 50%)
- Détecte les scénarios de disque de remplacement vide devenu actif par erreur

**Protection 2 : Historique des tailles**
- Enregistre les tailles de tous les datasets après chaque synchronisation réussie
- Compare avec l'historique lors des synchronisations suivantes
- Refuse si variation anormale détectée (> 20% depuis la dernière synchronisation)
- Fichier d'état : `/var/lib/zfs-nfs-replica/last-sync-sizes.txt`

Ces protections garantissent qu'un disque vide ne pourra jamais écraser accidentellement des données existantes.

### Health Checks des Disques Physiques

Le script intègre un système complet de vérification de santé des pools ZFS pour détecter proactivement les défaillances matérielles :

**Triple vérification de santé** (sur nœud actif et passif) :
1. **Présence des disques** : Vérifie que tous les disques physiques trackés via leur WWN (World Wide Name) ou identifiant ata-/scsi-/nvme- sont présents
2. **État du pool** : Contrôle que le pool est ONLINE (pas DEGRADED ou FAULTED)
3. **Espace libre** : Vérifie que l'espace libre est supérieur au seuil minimum (défaut: 5%)
4. **Erreurs I/O** : Détecte les erreurs de lecture/écriture/checksum sur les vdevs

**Tracking des disques** :
- Les disques sont identifiés par leur **WWN (World Wide Name)** en priorité pour garantir l'unicité
- Fallback sur les identifiants ata-/scsi-/nvme- si pas de WWN disponible
- Fichiers d'état : `/var/lib/zfs-nfs-replica/disk-uuids-{pool}.txt`
- Initialisation automatique au premier run

**Migration automatique en cas d'erreur critique** :
- Si un problème matériel est détecté sur le nœud actif, le LXC est automatiquement migré vers le nœud sain
- **Protection anti-ping-pong** : Cooldown de 1 heure pour éviter les migrations en boucle
- Notifications envoyées avant et après migration

### Système de Notifications via Apprise

Le script intègre [Apprise](https://github.com/caronc/apprise) pour envoyer des notifications sur 90+ services différents :

**Services supportés** (exemples) :
- Discord, Telegram, Slack
- Gotify, Ntfy, Pushover
- Email (SMTP, Gmail, etc.)
- SMS (Twilio, AWS SNS, etc.)
- Et beaucoup d'autres...

**Configuration** :
- Fichier de configuration externe : `/etc/zfs-nfs-replica/config`
- Exemple fourni : `config.example`
- Les paramètres persistent entre les mises à jour du script

**Modes de notification** :
- **INFO** : Toutes les notifications (démarrages, succès, erreurs)
- **ERROR** : Uniquement les erreurs critiques

**Types de notifications** :
- Réplication réussie (mode INFO uniquement)
- Pool dégradé détecté
- Disque(s) manquant(s)
- Migration automatique du LXC déclenchée
- Échec de réplication

**Installation** :
Apprise s'installe automatiquement dans un environnement Python virtuel isolé lors de la première exécution.

## Fonctionnalités

- **Mise à jour automatique** : Le script vérifie et installe automatiquement les nouvelles versions depuis le dépôt Forgejo avant chaque exécution
- **Réplication bidirectionnelle automatique** : S'adapte aux migrations Proxmox HA sans intervention manuelle
- **Détection automatique première sync/incrémentale** : Bascule automatiquement entre mode initial et mode incrémental
- **Configuration dynamique de Sanoid** : Configure automatiquement Sanoid en mode actif ou passif selon le rôle du nœud, conformément aux recommandations de la documentation officielle
- **Double protection anti-écrasement** : Vérifications de cohérence des tailles et historique pour prévenir toute perte de données
- **Health checks des disques physiques** : Triple vérification de santé des pools ZFS avec détection des disques manquants, pools dégradés, erreurs I/O et espace libre insuffisant
- **Notifications intelligentes via Apprise** : Système de notifications universel supportant 90+ services (Discord, Telegram, Gotify, Email, etc.) avec modes INFO et ERROR
- **Migration automatique en cas de défaillance** : Détecte les problèmes matériels critiques et migre automatiquement le LXC vers le nœud sain avec protection anti-ping-pong
- **Synchronisation récursive du pool** : Tous les datasets sous `zpool1` sont automatiquement inclus
- **Contrôle de concurrence par verrou** : Empêche les tâches de réplication simultanées
- **Gestion d'erreurs complète** : Valide la connectivité SSH, l'existence du pool et les opérations ZFS
- **Journalisation détaillée** : Toutes les opérations sont journalisées dans syslog (facility: local0)
- **Authentification SSH dédiée** : Paire de clés SSH isolée pour la sécurité de la réplication
- **Connectivité basée sur IP** : Utilise des IPs statiques pour une communication inter-nœuds fiable

## Structure du Dépôt

```
.
├── README.md                    # Ce fichier
├── zfs-nfs-replica.sh           # Script principal de réplication (version 2.3.2)
├── zfs-nfs-replica.service      # Définition du service systemd
├── zfs-nfs-replica.timer        # Configuration du timer systemd
└── config.example               # Exemple de configuration pour les notifications
```

### Système de Mise à Jour Automatique

Le script intègre un système d'auto-update qui vérifie et installe automatiquement les nouvelles versions depuis le dépôt Forgejo :

**Fonctionnement** :
- Vérifie la version distante à chaque exécution du script
- Télécharge et compare avec la version locale
- Crée une sauvegarde de l'ancienne version (`.backup-X.Y.Z`)
- Installe la nouvelle version automatiquement
- Redémarre le script avec la nouvelle version
- Échoue en sécurité si la mise à jour rencontre une erreur

**Configuration** :
- Activé par défaut (`AUTO_UPDATE_ENABLED=true` dans le script)
- Peut être désactivé en modifiant `AUTO_UPDATE_ENABLED=false`
- Dépôt source : `https://forgejo.tellserv.fr/Tellsanguis/zfs-sync-nfs-ha`

**Sécurité** :
- Protection contre les boucles infinies (variable `SKIP_AUTO_UPDATE`)
- Sauvegarde automatique avant mise à jour
- Restauration en cas d'échec
- Journalisation complète des opérations de mise à jour

## Utilisation

### Surveillance

```bash
# Vérifier l'état de la réplication
systemctl status zfs-nfs-replica.timer
journalctl -u zfs-nfs-replica.service

# Voir les snapshots sur tous les datasets
zfs list -t snapshot -r zpool1

# Comparer les snapshots entre les nœuds
diff <(ssh root@192.168.100.10 "zfs list -t snapshot -r zpool1 -o name") \
     <(ssh root@192.168.100.20 "zfs list -t snapshot -r zpool1 -o name")

# Vérifier quel nœud est actif
ha-manager status
pct status 103
```

### Réplication Manuelle

```bash
# Déclencher la réplication manuellement
/usr/local/sbin/zfs-nfs-replica.sh

# Tester le comportement de basculement
ha-manager migrate ct:103 elitedesk
```

## Principes de Conception

- **Source de vérité** : Le nœud exécutant le conteneur LXC est toujours le maître
- **Sécurité d'abord** : Triple vérification empêche la réplication depuis le mauvais nœud
- **Portée complète du pool** : L'intégralité de zpool1 est répliquée récursivement, pas les datasets individuels
- **Opération asynchrone** : Réplication indépendante des E/S NFS (intervalles de 10 minutes)
- **Adaptation automatique** : Aucune intervention manuelle nécessaire lors des migrations HA
- **Pools indépendants** : Chaque nœud maintient son propre pool non-mirroré

## Spécifications Techniques

- **Intervalle de réplication** : 10 minutes (configurable via le timer systemd)
- **Délai initial** : 5 minutes après le démarrage
- **Timeout de verrou** : Réplication concurrente empêchée via flock
- **Timeout SSH** : 5 secondes pour les vérifications de connectivité
- **Pool** : `zpool1` (codé en dur, doit exister sur les deux nœuds)
- **Conteneur** : CTID 103, nom `nfs-server`

## Prérequis

- Cluster Proxmox VE (testé sur 8.x)
- Pools ZFS nommés `zpool1` sur les nœuds de production
- **Configuration du mount point LXC pour HA** : Le mount point dans la configuration du LXC doit avoir l'option `shared=1` pour permettre le montage sur différents nœuds lors des migrations
  ```
  mp0: /zpool1/data-nfs-share,mp=/data-nfs-share,shared=1
  ```
- Sanoid/Syncoid installés depuis le dépôt officiel Sanoid
- **Python 3.13+ avec venv** : Requis pour le système de notifications Apprise
  ```bash
  # Sur Debian/Proxmox
  apt install python3.13-venv
  # Ou version plus récente selon votre distribution
  ```
- Paire de clés SSH dédiée pour la réplication
- Conteneur LXC avec rootfs sur LINSTOR/DRBD
- Configuration Proxmox HA avec paramètres de priorité appropriés

## Limitations et Considérations

- **RPO** : Un intervalle de réplication de 10 minutes signifie une perte de données potentielle jusqu'à 10 minutes dans des scénarios catastrophiques
- **Bande passante USB** : Vitesse de réplication limitée par le débit USB 3.0 (adapté aux données froides)
- **Première synchronisation** : La détection automatique et les protections de sécurité peuvent nécessiter 10-20 minutes lors de la première exécution
- **Point unique de défaillance** : Une panne du nœud actif nécessite une migration HA avant que les données ne soient accessibles
- **Dépendance réseau** : La réplication nécessite une connectivité réseau stable entre les nœuds

## Licence

Ce projet est fourni tel quel pour un usage éducatif et en production. N'hésitez pas à l'adapter à vos besoins d'infrastructure.

## Auteur

BENE Maël

Développé pour une infrastructure NFS hautement disponible de homelab utilisant du matériel standard et des logiciels open-source.
