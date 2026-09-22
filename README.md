---

<!-- FAST_ASSET_CACHE -->
## Fast Asset Cache — confirmed performance finding

LWCompat testing uncovered a significant Wine/Proton startup bottleneck in Last War's asset cache.

The game stores more than 22,000 asset bundle files in a single directory:

    Cache/AssetBundles
    ├─ ~6.0 GB
    └─ 22,197+ bundle files

On a case-sensitive Btrfs filesystem, Wine repeatedly performs directory enumeration while resolving Windows-style case-insensitive file lookups.

Profiling showed the startup path spending substantial CPU time in:

    NtQueryFullAttributesFile
    └─ get_nt_and_unix_names
       └─ lookup_unix_name
          └─ find_file_in_dir
             └─ getdents64
                └─ btrfs_real_readdir

During a 20-second startup trace:

    Btrfs / normal directory
    AssetBundles getdents64 calls : 88,503
    Total getdents64 calls        : 104,676

    ext4 casefold AssetBundles
    AssetBundles getdents64 calls : 0
    Total getdents64 calls        : 15,818

Using an ext4 filesystem with native casefold support for only the `AssetBundles` directory reduced directory-enumeration calls by roughly 85%.

Measured warm-cache startup results:

    Btrfs baseline
    Base ready             : ~53.0 s
    LastWar.exe → base     : ~45.7 s

    ext4 casefold test
    Base ready             : 40.2 s
                             36.3 s
                             34.8 s

    LastWar.exe → base     : 31.2 s
                             28.4 s
                             26.7 s

This represents a substantial reduction in startup time without changing game files, graphics settings, DXVK shader cache contents, or the launcher bridge.

### Fast Asset Cache implementation

LWCompat now includes an optional **Fast Asset Cache** feature that automates this optimization:

    First setup
      → create a sparse ext4 image with casefold support
      → migrate existing AssetBundles once
      → validate the cache
      → configure persistent mounting

    Normal launch
      → ensure Fast Asset Cache is mounted
      → expose it transparently at Cache/AssetBundles
      → launch normally

The goal is to require elevated privileges only during initial setup and avoid copying the multi-gigabyte asset cache on every launch.

> Status: implemented and available through the LWCompat installer.

### Fast Asset Cache management

The feature can be managed after installation with:

    lwcompat-fast-cache status
    lwcompat-fast-cache enable
    lwcompat-fast-cache disable

Disabling the feature immediately falls back to the original game cache on the host filesystem.

Fast Asset Cache cannot be enabled or disabled while Last War is running.

During normal uninstall, the cache image is preserved so it can be reused by a future LWCompat installation.

To remove it permanently:

    ./uninstall.sh --purge-fast-cache

