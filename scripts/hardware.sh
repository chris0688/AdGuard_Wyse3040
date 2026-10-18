# hardware.sh – Geräteerkennung, wird von install.sh eingebunden (source).
# Gibt den Namen des passenden Ordners unter hardware/ aus, oder nichts.

detect_hardware() {
    local product
    product="$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
    case "${product,,}" in
        *wyse*3040*) echo wyse3040 ;;
    esac
}
