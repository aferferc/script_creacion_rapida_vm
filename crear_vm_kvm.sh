#!/usr/bin/env bash
#===============================================================================
# crear_vm_kvm.sh
#
# Automatiza la creación de máquinas virtuales KVM/QEMU a partir de imágenes
# cloud base, usando discos QCOW2 diferenciales (backing file) y cloud-init
# inyectado directamente por virt-install (--cloud-init).
#
# Uso:  sudo ./crear_vm_kvm.sh
#       sudo RUTA_CLAVE_PUBLICA=/home/usuario/.ssh/id_ed25519.pub ./crear_vm_kvm.sh
#===============================================================================

set -Eeuo pipefail

#-------------------------------------------------------------------------------
# CONFIGURACIÓN GLOBAL (modificar aquí)
#-------------------------------------------------------------------------------

# Ruta de la clave pública SSH del host que se inyectará en la VM.
# Puede sobrescribirse desde el entorno (con sudo, $HOME suele ser el de root).
RUTA_CLAVE_PUBLICA="${RUTA_CLAVE_PUBLICA:-${HOME}/.ssh/id_rsa.pub}"

readonly DOMINIO="alfredo.org"                     # Sufijo del FQDN
readonly RED_LIBVIRT="default"                     # Red de libvirt a usar
readonly DIR_BASE="/var/lib/libvirt/images/base"   # Imágenes base (plantillas)
readonly DIR_DISCOS="/var/lib/libvirt/images"      # Discos de las VMs

#-------------------------------------------------------------------------------
# CATÁLOGO DE SISTEMAS OPERATIVOS (fácil de ampliar)
#
# Para añadir un SO: 1) añade su ID a SO_IDS (el orden define el menú) y
#                    2) rellena las cinco tablas asociativas con ese ID.
#
#   SO_GRUPO_ADMIN: grupo de administración de la distro (sudo, wheel, admin...).
#                   Se crea si no existe, se añade el usuario y se le concede
#                   sudo sin contraseña.
#
# Los os-variant válidos se consultan con:  virt-install --osinfo list
#-------------------------------------------------------------------------------
declare -a SO_IDS=("debian" "ubuntu" "fedora" "rocky" "alpine")

declare -A SO_DESCRIPCION=(
    ["debian"]="Debian 13 (Trixie)"
    ["ubuntu"]="Ubuntu 26.04 (Resolute Racoom)"
    ["fedora"]="Fedora 44 Cloud"
    ["rocky"]="Rocky Linux 10.2"
    ["alpine"]="Alpine Linux 3.24.2"
)
declare -A SO_IMAGEN=(
    ["debian"]="${DIR_BASE}/debian-13-generic-amd64.qcow2"
    ["ubuntu"]="${DIR_BASE}/resolute-server-cloudimg-amd64.qcow2"
    ["fedora"]="${DIR_BASE}/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2"
    ["rocky"]="${DIR_BASE}/Rocky-10-GenericCloud-LVM.latest.x86_64.qcow2"
    ["alpine"]="${DIR_BASE}/alpine-3.24.2-x86_64-cloudinit-r0.qcow2"
    
)
declare -A SO_VARIANT=(
    ["debian"]="debian13"
    ["ubuntu"]="ubuntu25.04"
    ["fedora"]="fedora42"
    ["rocky"]="rocky9"
    ["alpine"]="alpinelinux3.21"
)
declare -A SO_USUARIO=(            # Usuario por defecto de cada imagen cloud
    ["debian"]="debian"
    ["ubuntu"]="ubuntu"
    ["fedora"]="fedora"
    ["rocky"]="rocky"
    ["alpine"]="alpine"
)
declare -A SO_GRUPO_ADMIN=(        # Grupo con privilegios de administración
    ["debian"]="sudo"
    ["ubuntu"]="sudo"
    ["fedora"]="wheel"
    ["rocky"]="wheel"
    ["alpine"]="wheel"
)

#-------------------------------------------------------------------------------
# VARIABLES DE ESTADO (se rellenan durante la ejecución)
#-------------------------------------------------------------------------------
VM_NOMBRE=""        # Nombre de la VM
SO_ID=""            # ID del SO elegido
VM_DISCO_TAM=""     # Tamaño del disco (ej. 20G)
VM_CPUS=""          # Número de vCPUs
VM_RAM=""           # RAM en MB
VM_PASSWORD=""      # Contraseña del usuario por defecto
VM_DISCO=""         # Ruta del disco QCOW2 creado
TMP_CI=""           # Directorio temporal con user-data / meta-data
DISCO_CREADO=0      # Flag para limpieza en caso de error

#-------------------------------------------------------------------------------
# UTILIDADES DE MENSAJES Y LIMPIEZA
#-------------------------------------------------------------------------------
info()  { printf '[INFO]  %s\n' "$*"; }
aviso() { printf '[AVISO] %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

# Se ejecuta siempre al salir: borra temporales y, si hubo fallo, revierte
# el disco creado para no dejar basura.
finalizar() {
    local codigo=$?
    if [[ -n "$TMP_CI" && -d "$TMP_CI" ]]; then
        rm -rf "$TMP_CI"
    fi
    if (( codigo != 0 )) && (( DISCO_CREADO )) && [[ -f "$VM_DISCO" ]]; then
        aviso "Revirtiendo: eliminando disco ${VM_DISCO}"
        rm -f "$VM_DISCO"
    fi
}
trap finalizar EXIT
trap 'exit 130' INT TERM

#-------------------------------------------------------------------------------
# validar_catalogo: comprueba que cada ID de SO_IDS tiene entrada en las cinco
# tablas. Evita errores crípticos ("variable sin definir") por claves mal escritas.
#-------------------------------------------------------------------------------
validar_catalogo() {
    local id faltan

    for id in "${SO_IDS[@]}"; do
        faltan=""
        [[ -n "${SO_DESCRIPCION[$id]:-}" ]] || faltan+=" SO_DESCRIPCION"
        [[ -n "${SO_IMAGEN[$id]:-}"      ]] || faltan+=" SO_IMAGEN"
        [[ -n "${SO_VARIANT[$id]:-}"     ]] || faltan+=" SO_VARIANT"
        [[ -n "${SO_USUARIO[$id]:-}"     ]] || faltan+=" SO_USUARIO"
        [[ -n "${SO_GRUPO_ADMIN[$id]:-}" ]] || faltan+=" SO_GRUPO_ADMIN"
        [[ -z "$faltan" ]] \
            || die "Catálogo incompleto: el ID '${id}' no tiene entrada en:${faltan}"
    done
}

#-------------------------------------------------------------------------------
# comprobar_requisitos: root, herramientas, soporte --cloud-init y clave SSH.
#-------------------------------------------------------------------------------
comprobar_requisitos() {
    local cmd

    (( EUID == 0 )) || die "Este script debe ejecutarse con sudo/root."

    for cmd in qemu-img virt-install virsh; do
        command -v "$cmd" >/dev/null 2>&1 || die "Falta el comando requerido: ${cmd}"
    done

    # --cloud-init está disponible desde virt-install 4.0
    virt-install --help 2>&1 | grep -q -- '--cloud-init' \
        || die "Tu virt-install no soporta --cloud-init (se requiere 4.0 o superior)."

    [[ -r "$RUTA_CLAVE_PUBLICA" ]] \
        || die "No se puede leer la clave pública SSH: ${RUTA_CLAVE_PUBLICA}"

    virsh list >/dev/null 2>&1 \
        || die "No se puede conectar a libvirt. ¿Está libvirtd activo?"
}

#-------------------------------------------------------------------------------
# pedir_nombre: solicita y valida el nombre de la VM (hostname válido y único).
#-------------------------------------------------------------------------------
pedir_nombre() {
    local entrada
    while true; do
        read -r -p "Nombre de la VM: " entrada
        if [[ ! "$entrada" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
            error "Nombre no válido (usa minúsculas, números y guiones; sin empezar/terminar en guion)."
            continue
        fi
        if virsh dominfo "$entrada" >/dev/null 2>&1; then
            error "Ya existe una VM llamada '${entrada}'."
            continue
        fi
        if [[ -e "${DIR_DISCOS}/${entrada}.qcow2" ]]; then
            error "Ya existe el disco ${DIR_DISCOS}/${entrada}.qcow2."
            continue
        fi
        VM_NOMBRE="$entrada"
        return 0
    done
}

#-------------------------------------------------------------------------------
# seleccionar_so: muestra el menú del catálogo y verifica la imagen base.
#-------------------------------------------------------------------------------
seleccionar_so() {
    local total=${#SO_IDS[@]} i id eleccion

    echo
    echo "Sistemas operativos disponibles:"
    for (( i = 0; i < total; i++ )); do
        id="${SO_IDS[$i]}"
        printf '  %d) %s\n' "$(( i + 1 ))" "${SO_DESCRIPCION[$id]}"
    done

    while true; do
        read -r -p "Seleccione una opción [1-${total}]: " eleccion
        if [[ "$eleccion" =~ ^[0-9]+$ ]] && (( eleccion >= 1 && eleccion <= total )); then
            SO_ID="${SO_IDS[$(( eleccion - 1 ))]}"
            break
        fi
        error "Opción no válida."
    done

    # Comprobación de que la imagen base existe antes de continuar
    [[ -f "${SO_IMAGEN[$SO_ID]}" ]] \
        || die "No existe la imagen base: ${SO_IMAGEN[$SO_ID]}"
}

#-------------------------------------------------------------------------------
# pedir_disco: solicita el tamaño del disco (número + M/G/T, ej. 20G).
#-------------------------------------------------------------------------------
pedir_disco() {
    local entrada
    while true; do
        read -r -p "Tamaño del disco (ej. 20G): " entrada
        entrada="${entrada^^}"
        if [[ "$entrada" =~ ^[1-9][0-9]*[MGT]$ ]]; then
            VM_DISCO_TAM="$entrada"
            return 0
        fi
        error "Formato no válido. Ejemplos: 512M, 20G, 1T."
    done
}

#-------------------------------------------------------------------------------
# pedir_recursos: solicita vCPUs y RAM (estrictamente en MB).
#-------------------------------------------------------------------------------
pedir_recursos() {
    local entrada

    while true; do
        read -r -p "Número de vCPUs: " entrada
        if [[ "$entrada" =~ ^[1-9][0-9]*$ ]]; then
            VM_CPUS="$entrada"
            break
        fi
        error "Introduce un número entero mayor que 0."
    done

    while true; do
        read -r -p "Memoria RAM en MB (ej. 2048): " entrada
        if [[ "$entrada" =~ ^[0-9]+$ ]] && (( entrada >= 256 )); then
            VM_RAM="$entrada"
            break
        fi
        error "Introduce un número entero de MB (mínimo 256)."
    done
}

#-------------------------------------------------------------------------------
# pedir_password: solicita la contraseña (oculta) con confirmación.
#-------------------------------------------------------------------------------
pedir_password() {
    local usuario="${SO_USUARIO[$SO_ID]}" p1 p2
    while true; do
        read -r -s -p "Contraseña para el usuario '${usuario}': " p1; echo
        read -r -s -p "Repite la contraseña: " p2; echo
        if [[ -z "$p1" ]]; then
            error "La contraseña no puede estar vacía."
        elif [[ "$p1" != "$p2" ]]; then
            error "Las contraseñas no coinciden."
        else
            VM_PASSWORD="$p1"
            return 0
        fi
    done
}

#-------------------------------------------------------------------------------
# pedir_datos: orquesta toda la entrada interactiva y pide confirmación.
#-------------------------------------------------------------------------------
pedir_datos() {
    local confirmar

    pedir_nombre
    seleccionar_so
    pedir_disco
    pedir_recursos
    pedir_password

    echo
    echo "==================== RESUMEN ===================="
    echo " Nombre     : ${VM_NOMBRE}  (${VM_NOMBRE}.${DOMINIO})"
    echo " SO         : ${SO_DESCRIPCION[$SO_ID]} [${SO_VARIANT[$SO_ID]}]"
    echo " Imagen base: ${SO_IMAGEN[$SO_ID]}"
    echo " Disco      : ${VM_DISCO_TAM}"
    echo " vCPUs      : ${VM_CPUS}"
    echo " RAM        : ${VM_RAM} MB"
    echo " Usuario    : ${SO_USUARIO[$SO_ID]} (grupo ${SO_GRUPO_ADMIN[$SO_ID]})"
    echo "================================================="
    read -r -p "¿Crear la VM con estos datos? [s/N]: " confirmar
    [[ "${confirmar,,}" =~ ^(s|si|sí|y|yes)$ ]] || die "Operación cancelada por el usuario."
}

#-------------------------------------------------------------------------------
# crear_disco: crea un QCOW2 diferencial (backing file) con el tamaño pedido.
#-------------------------------------------------------------------------------
crear_disco() {
    local base="${SO_IMAGEN[$SO_ID]}" formato_base

    VM_DISCO="${DIR_DISCOS}/${VM_NOMBRE}.qcow2"

    # Detecta el formato real de la imagen base (-U: no falla si está en uso)
    formato_base="$(qemu-img info -U "$base" | awk -F': ' '/^file format:/ {print $2}')"
    [[ -n "$formato_base" ]] || die "No se pudo determinar el formato de ${base}"

    info "Creando disco diferencial ${VM_DISCO} (${VM_DISCO_TAM}) sobre ${base}"
    qemu-img create -q -f qcow2 -F "$formato_base" -b "$base" "$VM_DISCO" "$VM_DISCO_TAM" \
        || die "Falló qemu-img (¿el tamaño es menor que el de la imagen base?)"
    DISCO_CREADO=1
}

#-------------------------------------------------------------------------------
# generar_cloudinit: escribe user-data y meta-data en un directorio temporal.
# virt-install los consumirá directamente con --cloud-init.
#-------------------------------------------------------------------------------
generar_cloudinit() {
    local usuario="${SO_USUARIO[$SO_ID]}"
    local grupo="${SO_GRUPO_ADMIN[$SO_ID]}"
    local clave_ssh pass_yaml

    clave_ssh="$(< "$RUTA_CLAVE_PUBLICA")"

    # La contraseña se escribe en texto plano dentro del user-data (cloud-init
    # la hashea al aplicarla). Se escapan las comillas simples para que sea un
    # escalar YAML válido entre comillas simples.
    pass_yaml="${VM_PASSWORD//\'/\'\'}"

    # Directorio temporal en /tmp (modo 700): desaparece al salir del script
    # (trap) y, en cualquier caso, al reiniciar el host.
    TMP_CI="$(mktemp -d /tmp/kvm-cloudinit.XXXXXX)"

    # --- user-data: identidad, usuarios, sudoers y bloqueo de root ---
    cat > "${TMP_CI}/user-data" <<EOF
#cloud-config
hostname: ${VM_NOMBRE}
fqdn: ${VM_NOMBRE}.${DOMINIO}
manage_etc_hosts: true

# Impide el acceso directo como root
disable_root: true

# Garantiza que el grupo de administración existe en cualquier distro
groups:
  - ${grupo}

users:
  - name: ${usuario}
    gecos: Usuario por defecto
    shell: /bin/bash
    groups: [${grupo}]
    lock_passwd: false
    ssh_authorized_keys:
      - ${clave_ssh}

# Asigna la contraseña (cloud-init la convierte en hash dentro de la VM)
chpasswd:
  expire: false
  users:
    - name: ${usuario}
      password: '${pass_yaml}'
      type: text

write_files:
  # Cualquier miembro del grupo de administración usa sudo sin contraseña
  - path: /etc/sudoers.d/90-${grupo}-nopasswd
    owner: root:root
    permissions: '0440'
    content: |
      %${grupo} ALL=(ALL:ALL) NOPASSWD:ALL

runcmd:
  # Bloquea la contraseña de root
  - [ passwd, -l, root ]
EOF

    # --- meta-data: identificador único de instancia y hostname ---
    cat > "${TMP_CI}/meta-data" <<EOF
instance-id: ${VM_NOMBRE}-$(date +%s)
local-hostname: ${VM_NOMBRE}
EOF

    # El user-data contiene la contraseña: solo lectura/escritura para root
    chmod 600 "${TMP_CI}/user-data" "${TMP_CI}/meta-data"
}

#-------------------------------------------------------------------------------
# desplegar_vm: lanza virt-install con disco y red virtio y cloud-init.
#-------------------------------------------------------------------------------
desplegar_vm() {
    info "Desplegando la VM '${VM_NOMBRE}'..."
    virt-install \
        --name "$VM_NOMBRE" \
        --memory "$VM_RAM" \
        --vcpus "$VM_CPUS" \
        --cpu host-model \
        --os-variant "${SO_VARIANT[$SO_ID]}" \
        --import \
        --disk "path=${VM_DISCO},format=qcow2,bus=virtio" \
        --network "network=${RED_LIBVIRT},model=virtio" \
        --cloud-init "user-data=${TMP_CI}/user-data,meta-data=${TMP_CI}/meta-data" \
        --noautoconsole \
        || die "Falló virt-install"
}

#-------------------------------------------------------------------------------
# mostrar_final: indica cómo localizar la VM y conectarse a ella.
#-------------------------------------------------------------------------------
mostrar_final() {
    echo
    info "VM '${VM_NOMBRE}' creada correctamente."
    echo "  Obtener IP : sudo virsh domifaddr ${VM_NOMBRE}"
    echo "  Conectar   : ssh ${SO_USUARIO[$SO_ID]}@<IP>   (o ${VM_NOMBRE}.${DOMINIO} si resuelve)"
    echo "  Consola    : sudo virsh console ${VM_NOMBRE}"
}

#-------------------------------------------------------------------------------
# main: flujo principal.
#-------------------------------------------------------------------------------
main() {
    validar_catalogo
    comprobar_requisitos
    pedir_datos
    crear_disco
    generar_cloudinit
    desplegar_vm
    mostrar_final
}

main "$@"