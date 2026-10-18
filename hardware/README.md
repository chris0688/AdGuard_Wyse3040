# Hardware-spezifische Anpassungen

Jeder Unterordner ist wie `rootfs/` aufgebaut und wird von `scripts/install.sh`
**nur** eingespielt, wenn das Gerät erkannt wird. Erkannt wird über den
Produktnamen aus dem BIOS (`/sys/class/dmi/id/product_name`), siehe
`detect_hardware()` in [`scripts/hardware.sh`](../scripts/hardware.sh).

| Ordner | Gerät | Inhalt |
|--------|-------|--------|
| `wyse3040/` | Dell Wyse 3040 | sperrt den DMA-Treiber `dw_dmac`, sonst hängt das Gerät beim Herunterfahren/Neustarten |

Neues Gerät hinzufügen: Ordner anlegen und in `detect_hardware()` ein Muster
für den Produktnamen ergänzen. Produktname anzeigen:
`cat /sys/class/dmi/id/product_name`
