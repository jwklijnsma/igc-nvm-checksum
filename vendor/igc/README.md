# Bundled igc driver sources

Unmodified copies of `drivers/net/ethernet/intel/igc` from the Linux stable tree
(GPL-2.0, © Intel Corporation and contributors), one directory per tag.

The installer copies them to `/usr/share/igc-nvmfix/vendor/igc/`. The DKMS build
uses them when the exact source for a kernel can't be downloaded (offline): the
exact tag first, otherwise the newest bundled version of the same `major.minor`
series. The NVM patch is applied at build time, so these stay pristine.

To add a series, run on a machine with internet:

```bash
tag=v7.4.1
git clone --depth 1 --filter=blob:none --sparse --branch $tag https://github.com/gregkh/linux.git /tmp/k
git -C /tmp/k sparse-checkout set drivers/net/ethernet/intel/igc
mkdir -p vendor/igc/$tag && cp -a /tmp/k/drivers/net/ethernet/intel/igc/. vendor/igc/$tag/ && touch vendor/igc/$tag/.complete
```
