🌐 **Languages**

🇬🇧 [English](../README.md) | 🇫🇷 Français (actuel)

# AutoDC

**Déploiement complet d'un contrôleur de domaine Windows Server (ADDS + DNS + DHCP) depuis une seule interface graphique et sans surveillance.**

## Pourquoi ce script ?

Monter un contrôleur de domaine à la main enchaîne des étapes répétitives et entrecoupées de redémarrages (réseau → rôles → promotion → DNS/DHCP). AutoDC regroupe toute la saisie dans une seule fenêtre, puis déroule le reste tout seul en gérant les reboots. Idéal pour monter et remonter rapidement des DC en lab sur des VM.

![Fenêtre principale d'AutoDC](main-window.png)

### Avantages
- Tout en une passe, sans intervention après la saisie (redémarrages gérés, reprise automatique).
- Interface façon assistant Windows Server, avec validations intégrées et aperçu des commandes avant exécution.
- Configuration réutilisable (import/export) ; les mots de passe ne sont jamais stockés en clair.

### Limites
- Windows Server 2019 / 2022 / 2025 uniquement (PowerShell 5.1+).
- Pensé pour le lab, pas pour un environnement de production critique.
- Le serveur redémarre automatiquement → à lancer depuis la console de la VM, pas en RDP.
- AutoDC installe le DC mais ne peuple pas le domaine (OU, utilisateurs, groupes) — c'est le rôle de son outil compagnon [**ADFlow**](https://github.com/Aractuse/ADFlow).

## Démarrage rapide

1. Copiez `Start-AutoDC.ps1` sur le serveur, puis clic droit → Exécuter avec PowerShell (il s'élève tout seul en administrateur).
2. Remplissez les onglets (Serveur → Réseau → Rôles → ADDS/DNS/DHCP → Prerequisites) et cliquez sur **Launch**.
3. Laissez faire : la configuration s'applique, le serveur redémarre une à deux fois et termine seul. Une fenêtre affiche la progression en direct à l'ouverture de session.

```powershell
# En console administrateur, dans le dossier du script :
powershell -ExecutionPolicy Bypass -File .\Start-AutoDC.ps1
```

> ⚠️ Le serveur redémarre pendant le déploiement : lancez-le depuis la **console** de la VM (une reconfiguration réseau peut couper une session RDP).

![Déroulé complet](demo.gif)

![Commande preview](preview.png)

## Comment ça marche

Le déploiement traverse plusieurs phases qui survivent aux redémarrages grâce à des tâches planifiées auto-nettoyées :

```
Interactive  →  (rename + reboot)  →  Promote (promotion ADDS + reboot)  →  Configure (DNS + DHCP)
```

Les secrets (DSRM, admin de domaine) sont chiffrés via **DPAPI (portée machine)** le temps des reboots, puis effacés — jamais en clair sur le disque ni dans le fichier de configuration exporté.

## Auteur

**Taeckens.M** — voir aussi [**ADFlow**](https://github.com/Aractuse/ADFlow), l'outil compagnon qui *remplit* le domaine (OU, utilisateurs, groupes…) à partir d'un simple fichier de définition.
