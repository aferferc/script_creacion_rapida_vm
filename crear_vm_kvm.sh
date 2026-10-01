#!/bin/env sh
#===============================================================================
# crear_vm_kvm.sh
#
# Automatiza la creación de máquinas virtuales KVM/QEMU a partir de imágenes
# cloud base, usando discos QCOW2 diferenciales (backing file) y cloud-init
# inyectado directamente por virt-install (--cloud-init).
#
# Script compatible con POSIX sh (dash, ash/busybox, bash en modo sh...):
# sin arrays, sin [[ ]], sin 'local' y sin otras extensiones de bash.
#
# Uso:  sudo ./crear_vm_kvm.sh      (o: sudo sh crear_vm_kvm.sh)
#===============================================================================

set -eu

#-------------------------------------------------------------------------------
# CONFIGURACIÓN GLOBAL (modificar aquí)
#-------------------------------------------------------------------------------

# Clave pública SSH del host que se inyectará en la VM: pega aquí la línea
# completa de tu fichero .pub. Ejemplo:
#   CLAVE_PUBLICA_SSH="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... usuario@host"
readonly CLAVE_PUBLICA_SSH=""

readonly DOMINIO="example.org"                     # Sufijo del FQDN
readonly RED_LIBVIRT="default"                     # Red de libvirt a usar
readonly DIR_BASE="/var/lib/libvirt/images/base"   # Imágenes base (plantillas)
readonly DIR_DISCOS="/var/lib/libvirt/images"      # Discos de las VMs

#-------------------------------------------------------------------------------
# CATÁLOGO DE SISTEMAS OPERATIVOS (fácil de ampliar)
#
# Una línea por sistema, con siete campos separados por "|":
#
#   id | descripción | imagen base | os-variant | usuario por defecto | grupo admin | shell
#
#   - id:            identificador interno único (sin espacios).
#   - descripción:   texto que se muestra en el menú (el orden define el menú).
#   - imagen base:   ruta del disco cloud que se usará como backing file.
#   - os-variant:    valor para virt-install (virt-install --osinfo list).
#   - usuario:       usuario por defecto de la imagen cloud.
#   - grupo admin:   grupo de superusuarios de la distro (sudo, wheel, etc).
#   - shell:         shell de los usuarios creados. DEBE existir en la imagen: si
#                    no, sshd rechaza el login (p. ej. Alpine no trae bash: /bin/sh).
#
# MUY IMPORTANTE, antes de añadir un SO revisa que paramtros poner en internet
#
# Se ignoran las líneas vacías y las que empiezan por "#".
# No escribas el carácter "|" dentro de ningún campo.
#-------------------------------------------------------------------------------
CATALOGO="
debian|Debian 13 (Trixie)|${DIR_BASE}/debian-13-generic-amd64.qcow2|debian13|debian|sudo|/bin/bash

ubuntu|Ubuntu 26.04 (Resolute Racoom)|${DIR_BASE}/resolute-server-cloudimg-amd64.qcow2|ubuntu25.04|ubuntu|sudo|/bin/bash

fedora|Fedora 44 Cloud|${DIR_BASE}/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2|fedora42|fedora|wheel|/bin/bash

rocky|Rocky Linux 10.2|${DIR_BASE}/Rocky-10-GenericCloud-LVM.latest.x86_64.qcow2|rocky9|rocky|wheel|/bin/bash

alpine|Alpine Linux 3.24.2|${DIR_BASE}/alpine-3.24.2-x86_64-cloudinit-r0.qcow2|alpinelinux3.21|alpine|wheel|/bin/sh
"

#-------------------------------------------------------------------------------
# VARIABLES DE ESTADO (se rellenan durante la ejecución, es decit, NO TOCAR)
#
# POSIX sh no tiene 'local': las variables auxiliares de cada función llevan un
# prefijo propio (pn_, so_, pd_...) para evitar colisiones.
#-------------------------------------------------------------------------------
SO_ID=""            # Datos del SO elegido (campos del catálogo)
SO_DESC=""
SO_IMAGEN=""
SO_VARIANT=""
SO_USUARIO=""       # Usuario por defecto de la imagen
SO_GRUPO=""         # Grupo de superusuarios de la distro
SO_SHELL=""         # Shell de los usuarios creados (debe existir en la imagen)
VM_NOMBRE=""        # Nombre de la VM
VM_USUARIO=""       # Usuario final de la VM (nuevo o el de por defecto)
VM_USUARIO_NUEVO=0  # 1 si se crea un usuario distinto al de por defecto
VM_PASSWORD=""      # Contraseña del usuario (vacía = sin contraseña)
VM_DISCO_TAM=""     # Tamaño del disco (ej. 20G)
VM_CPUS=""          # Número de vCPUs
VM_RAM=""           # RAM en MB
VM_DISCO=""         # Ruta del disco QCOW2 creado
TMP_CI=""           # Directorio temporal con user-data / meta-data
DISCO_CREADO=0      # Flag para limpieza en caso de error
RESPUESTA=""        # Último valor leído por preguntar / preguntar_oculto

#-------------------------------------------------------------------------------
# UTILIDADES GENERALES
#-------------------------------------------------------------------------------
info()  { printf '[INFO]  %s\n' "$*"; }
aviso() { printf '[AVISO] %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

# coincide REGEX TEXTO: devuelve 0 si TEXTO cumple la expresión regular extendida.
coincide() {
    printf '%s\n' "$2" | grep -Eq -- "$1"
}

# preguntar "texto": muestra el prompt y guarda la respuesta en $RESPUESTA.
preguntar() {
    printf '%s' "$1"
    read -r RESPUESTA || die "Entrada cancelada."
}

# preguntar_oculto "texto": como preguntar, pero sin mostrar lo que se escribe.
preguntar_oculto() {
    po_fallo=0
    printf '%s' "$1"
    if [ -t 0 ]; then stty -echo; fi
    IFS= read -r RESPUESTA || po_fallo=1
    if [ -t 0 ]; then stty echo; fi
    printf '\n'
    [ "$po_fallo" -eq 0 ] || die "Entrada cancelada."
}

# yaml_escapar TEXTO: duplica las comillas simples para usar TEXTO dentro de un
# escalar YAML entre comillas simples.
yaml_escapar() {
    printf '%s' "$1" | sed "s/'/''/g"
}

# catalogo_lineas: imprime las entradas útiles del catálogo (sin vacías/comentarios).
catalogo_lineas() {
    printf '%s\n' "$CATALOGO" | sed -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d'
}

# Se ejecuta siempre al salir: restaura el eco del terminal, borra temporales y,
# si hubo fallo, revierte el disco creado para no dejar basura.
finalizar() {
    fi_codigo=$?
    if [ -t 0 ]; then stty echo 2>/dev/null || :; fi
    if [ -n "$TMP_CI" ] && [ -d "$TMP_CI" ]; then
        rm -rf "$TMP_CI"
    fi
    if [ "$fi_codigo" -ne 0 ] && [ "$DISCO_CREADO" -eq 1 ] && [ -f "$VM_DISCO" ]; then
        aviso "Revirtiendo: eliminando disco ${VM_DISCO}"
        rm -f "$VM_DISCO"
    fi
}
trap finalizar EXIT
trap 'exit 130' INT TERM

#-------------------------------------------------------------------------------
# validar_catalogo: comprueba que cada entrada tiene sus siete campos rellenos.
# Evita errores crípticos por líneas mal escritas.
#-------------------------------------------------------------------------------
validar_catalogo() {
    vc_lineas="$(catalogo_lineas)"
    [ -n "$vc_lineas" ] || die "El catálogo de sistemas operativos está vacío."

    while IFS='|' read -r vc_id vc_desc vc_img vc_var vc_usr vc_grp vc_shell vc_extra; do
        if [ -z "$vc_id" ] || [ -z "$vc_desc" ] || [ -z "$vc_img" ] \
           || [ -z "$vc_var" ] || [ -z "$vc_usr" ] || [ -z "$vc_grp" ] \
           || [ -z "$vc_shell" ] || [ -n "$vc_extra" ]; then
            die "Entrada de catálogo mal formada (se esperan 7 campos): ${vc_id}|${vc_desc}|${vc_img}|${vc_var}|${vc_usr}|${vc_grp}|${vc_shell}"
        fi
    done <<EOF
$vc_lineas
EOF
}

#-------------------------------------------------------------------------------
# comprobar_requisitos: root, herramientas, soporte --cloud-init y clave SSH.
#-------------------------------------------------------------------------------
comprobar_requisitos() {
    cr_cmd=""

    [ "$(id -u)" -eq 0 ] || die "Este script debe ejecutarse con sudo/root."

    for cr_cmd in qemu-img virt-install virsh; do
        command -v "$cr_cmd" >/dev/null 2>&1 || die "Falta el comando requerido: ${cr_cmd}"
    done

    # --cloud-init está disponible desde virt-install 4.0
    virt-install --help 2>&1 | grep -q -- '--cloud-init' \
        || die "Tu virt-install no soporta --cloud-init (se requiere 4.0 o superior)."

    # La clave pública SSH debe estar definida en la configuración del script
    [ -n "$CLAVE_PUBLICA_SSH" ] \
        || die "Define CLAVE_PUBLICA_SSH al principio del script con tu clave pública SSH."
    [ "$(printf '%s\n' "$CLAVE_PUBLICA_SSH" | wc -l)" -eq 1 ] \
        || die "CLAVE_PUBLICA_SSH debe ser una única línea."
    coincide '^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/=]+( .*)?$' "$CLAVE_PUBLICA_SSH" \
        || die "CLAVE_PUBLICA_SSH no parece una clave pública SSH válida."

    virsh list >/dev/null 2>&1 \
        || die "No se puede conectar a libvirt. ¿Está libvirtd activo?"
}

#-------------------------------------------------------------------------------
# pedir_nombre: solicita y valida el nombre de la VM (hostname válido y único).
#-------------------------------------------------------------------------------
pedir_nombre() {
    while true; do
        preguntar "Nombre de la VM: "
        if ! coincide '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' "$RESPUESTA"; then
            error "Nombre no válido (usa minúsculas, números y guiones; sin empezar/terminar en guion)."
            continue
        fi
        if virsh dominfo "$RESPUESTA" >/dev/null 2>&1; then
            error "Ya existe una VM llamada '${RESPUESTA}'."
            continue
        fi
        if [ -e "${DIR_DISCOS}/${RESPUESTA}.qcow2" ]; then
            error "Ya existe el disco ${DIR_DISCOS}/${RESPUESTA}.qcow2."
            continue
        fi
        VM_NOMBRE="$RESPUESTA"
        return 0
    done
}

#-------------------------------------------------------------------------------
# seleccionar_so: muestra el menú del catálogo, carga los datos del SO elegido
# en las variables SO_* y verifica que la imagen base existe.
#-------------------------------------------------------------------------------
seleccionar_so() {
    so_total="$(catalogo_lineas | wc -l)"
    so_total=$(( so_total + 0 ))      # normaliza espacios de wc en algunos sistemas
    so_linea=""

    printf '\nSistemas operativos disponibles:\n'
    catalogo_lineas | {
        so_i=0
        while IFS='|' read -r so_m_id so_m_desc so_m_resto; do
            so_i=$(( so_i + 1 ))
            printf '  %d) %s\n' "$so_i" "$so_m_desc"
        done
    }

    while true; do
        preguntar "Seleccione una opción [1-${so_total}]: "
        if coincide '^[1-9][0-9]*$' "$RESPUESTA" \
           && [ "$RESPUESTA" -le "$so_total" ]; then
            break
        fi
        error "Opción no válida."
    done

    # Extrae la línea elegida y reparte sus campos en las variables SO_*
    so_linea="$(catalogo_lineas | sed -n "${RESPUESTA}p")"
    IFS='|' read -r SO_ID SO_DESC SO_IMAGEN SO_VARIANT SO_USUARIO SO_GRUPO SO_SHELL <<EOF
$so_linea
EOF

    # Comprobación de que la imagen base existe antes de continuar
    [ -f "$SO_IMAGEN" ] || die "No existe la imagen base: ${SO_IMAGEN}"
}

#-------------------------------------------------------------------------------
# pedir_disco: solicita el tamaño del disco (número + M/G/T, ej. 20G).
#-------------------------------------------------------------------------------
pedir_disco() {
    while true; do
        preguntar "Tamaño del disco (ej. 20G): "
        pd_tam="$(printf '%s' "$RESPUESTA" | tr '[:lower:]' '[:upper:]')"
        if coincide '^[1-9][0-9]*[MGT]$' "$pd_tam"; then
            VM_DISCO_TAM="$pd_tam"
            return 0
        fi
        error "Formato no válido. Ejemplos: 512M, 20G, 1T."
    done
}

#-------------------------------------------------------------------------------
# pedir_recursos: solicita vCPUs y RAM (estrictamente en MB).
#-------------------------------------------------------------------------------
pedir_recursos() {
    while true; do
        preguntar "Número de vCPUs: "
        if coincide '^[1-9][0-9]*$' "$RESPUESTA"; then
            VM_CPUS="$RESPUESTA"
            break
        fi
        error "Introduce un número entero mayor que 0."
    done

    while true; do
        preguntar "Memoria RAM en MB (ej. 2048): "
        if coincide '^[1-9][0-9]*$' "$RESPUESTA" && [ "$RESPUESTA" -ge 256 ]; then
            VM_RAM="$RESPUESTA"
            break
        fi
        error "Introduce un número entero de MB (mínimo 256)."
    done
}

#-------------------------------------------------------------------------------
# pedir_password: solicita la contraseña del usuario nuevo (oculta, con
# confirmación). Si se deja vacía, el usuario se crea sin contraseña.
#-------------------------------------------------------------------------------
pedir_password() {
    pp_p1=""
    VM_PASSWORD=""
    while true; do
        preguntar_oculto "Contraseña para '${VM_USUARIO}' (vacía = sin contraseña): "
        pp_p1="$RESPUESTA"
        if [ -z "$pp_p1" ]; then
            return 0
        fi
        preguntar_oculto "Repite la contraseña: "
        if [ "$pp_p1" = "$RESPUESTA" ]; then
            VM_PASSWORD="$pp_p1"
            return 0
        fi
        error "Las contraseñas no coinciden."
    done
}

#-------------------------------------------------------------------------------
# pedir_usuario: pregunta si se quiere crear un usuario propio.
#   - Con nombre:  ese usuario sustituye al usuario por defecto (será el
#                  usuario 1001 de la VM), entra en el grupo de superusuarios y
#                  se le pide contraseña (vacía = sin contraseña) el usuario con
#                  uid 1000 queda bloquedo.
#   - Sin nombre:  se mantiene el usuario por defecto del SO, también en el
#                  grupo de superusuarios y sin contraseña.
#-------------------------------------------------------------------------------
pedir_usuario() {
    printf '\n'
    while true; do
        preguntar "Usuario a crear (vacío = mantener el usuario por defecto '${SO_USUARIO}'): "

        # Sin nombre: usuario por defecto, sin contraseña
        if [ -z "$RESPUESTA" ]; then
            VM_USUARIO="$SO_USUARIO"
            VM_USUARIO_NUEVO=0
            VM_PASSWORD=""
            return 0
        fi

        if ! coincide '^[a-z_][a-z0-9_-]{0,31}$' "$RESPUESTA"; then
            error "Nombre de usuario no válido (minúsculas, números, '_' y '-'; máx. 32 caracteres)."
            continue
        fi
        if [ "$RESPUESTA" = "root" ]; then
            error "No se puede usar 'root' como usuario."
            continue
        fi

        # Con nombre: usuario nuevo, pide contraseña (opcional)
        VM_USUARIO="$RESPUESTA"
        VM_USUARIO_NUEVO=1
        pedir_password
        return 0
    done
}

#-------------------------------------------------------------------------------
# pedir_datos: orquesta toda la entrada interactiva y pide confirmación.
#-------------------------------------------------------------------------------
pedir_datos() {
    pdt_usuario=""
    pdt_pass=""
    pdt_conf=""

    pedir_nombre
    seleccionar_so
    pedir_disco
    pedir_recursos
    pedir_usuario

    if [ "$VM_USUARIO_NUEVO" -eq 1 ]; then
        pdt_usuario="${VM_USUARIO} (uid 1001)"
    else
        pdt_usuario="${VM_USUARIO} (usuario por defecto)"
    fi
    if [ -n "$VM_PASSWORD" ]; then
        pdt_pass="establecida"
    else
        pdt_pass="sin contraseña (solo acceso por clave)"
    fi

    printf '\n==================== RESUMEN ====================\n'
    printf ' Nombre     : %s  (%s.%s)\n' "$VM_NOMBRE" "$VM_NOMBRE" "$DOMINIO"
    printf ' SO         : %s [%s]\n' "$SO_DESC" "$SO_VARIANT"
    printf ' Imagen base: %s\n' "$SO_IMAGEN"
    printf ' Disco      : %s\n' "$VM_DISCO_TAM"
    printf ' vCPUs      : %s\n' "$VM_CPUS"
    printf ' RAM        : %s MB\n' "$VM_RAM"
    printf ' Usuario    : %s\n' "$pdt_usuario"
    printf ' Grupo admin: %s\n' "$SO_GRUPO"
    printf ' Contraseña : %s\n' "$pdt_pass"
    printf '=================================================\n'

    preguntar "¿Crear la VM con estos datos? [s/N]: "
    pdt_conf="$(printf '%s' "$RESPUESTA" | tr '[:upper:]' '[:lower:]')"
    case "$pdt_conf" in
        s|si|sí|y|yes) ;;
        *) die "Operación cancelada por el usuario." ;;
    esac
}

#-------------------------------------------------------------------------------
# crear_disco: crea un QCOW2 diferencial (backing file) con el tamaño pedido.
#-------------------------------------------------------------------------------
crear_disco() {
    cd_formato=""

    VM_DISCO="${DIR_DISCOS}/${VM_NOMBRE}.qcow2"

    # Detecta el formato real de la imagen base (-U: no falla si está en uso)
    cd_formato="$(qemu-img info -U "$SO_IMAGEN" | awk -F': ' '/^file format:/ {print $2}')"
    [ -n "$cd_formato" ] || die "No se pudo determinar el formato de ${SO_IMAGEN}"

    info "Creando disco diferencial ${VM_DISCO} (${VM_DISCO_TAM}) sobre ${SO_IMAGEN}"
    qemu-img create -q -f qcow2 -F "$cd_formato" -b "$SO_IMAGEN" "$VM_DISCO" "$VM_DISCO_TAM" \
        || die "Falló qemu-img (¿el tamaño es menor que el de la imagen base?)"
    DISCO_CREADO=1
}

#-------------------------------------------------------------------------------
# generar_cloudinit: escribe user-data y meta-data en un directorio temporal.
# virt-install los consumirá directamente con --cloud-init.
#
# El bloque 'users' NO incluye 'default', así que cloud-init no crea el usuario
# por defecto de la imagen: el único usuario definido (el nuevo, o el de por
# defecto si no se pidió otro) es el primero en crearse y recibe el UID 1000.
#-------------------------------------------------------------------------------
generar_cloudinit() {
    gc_clave="$(yaml_escapar "$CLAVE_PUBLICA_SSH")"
    gc_pass=""

    # Directorio temporal en /tmp (modo 700): desaparece al salir del script
    # (trap) y, en cualquier caso, al reiniciar el host.
    TMP_CI="$(mktemp -d /tmp/kvm-cloudinit.XXXXXX)"

    if [ -n "$VM_PASSWORD" ]; then
        gc_pass="$(yaml_escapar "$VM_PASSWORD")"
    fi

    # --- user-data (parte 1): identidad y usuario ---
    cat > "${TMP_CI}/user-data" <<EOF
#cloud-config
hostname: ${VM_NOMBRE}
fqdn: ${VM_NOMBRE}.${DOMINIO}
manage_etc_hosts: true

# Impide el acceso directo como root
disable_root: true

# Garantiza que el grupo de superusuarios existe en cualquier distro
groups:
  - ${SO_GRUPO}

users:
  - name: ${VM_USUARIO}
    gecos: Usuario administrador
    shell: ${SO_SHELL}
    groups: [${SO_GRUPO}]
    lock_passwd: false
    ssh_authorized_keys:
      - '${gc_clave}'
EOF

    # --- user-data (parte 2, opcional): contraseña del usuario ---
    if [ -n "$VM_PASSWORD" ]; then
        cat >> "${TMP_CI}/user-data" <<EOF

# Asigna la contraseña (cloud-init la convierte en hash dentro de la VM)
chpasswd:
  expire: false
  users:
    - name: ${VM_USUARIO}
      password: '${gc_pass}'
      type: text
EOF
    fi

    # --- user-data (parte 3): sudoers y bloqueo de root ---
    cat >> "${TMP_CI}/user-data" <<EOF

write_files:
  # Cualquier miembro del grupo de superusuarios usa sudo sin contraseña
  - path: /etc/sudoers.d/90-${SO_GRUPO}-nopasswd
    owner: root:root
    permissions: '0440'
    content: |
      %${SO_GRUPO} ALL=(ALL:ALL) NOPASSWD:ALL

runcmd:
  # Bloquea la contraseña de root
  - [ passwd, -l, root ]
EOF

    # --- user-data (parte 4, opcional): usuario sin contraseña ---
    # Una cuenta sin contraseña queda con el campo de /etc/shadow en "!" (bloqueada).
    # sshd sin PAM (p. ej. Alpine) rechaza las cuentas bloqueadas aunque la clave SSH
    # sea correcta. Se cambia el campo a "*": impide el login por contraseña, pero
    # permite el acceso por clave. Solo se toca si el campo contiene únicamente "!"/"*",
    # es decir, nunca se modifica un hash real.
    if [ -z "$VM_PASSWORD" ]; then
        cat >> "${TMP_CI}/user-data" <<EOF
  # Usuario sin contraseña: acceso solo por clave SSH (cuenta no bloqueada)
  - [ sed, -i, 's/^${VM_USUARIO}:[!*]*:/${VM_USUARIO}:*:/', /etc/shadow ]
EOF
    fi

    # --- meta-data: identificador único de instancia y hostname ---
    cat > "${TMP_CI}/meta-data" <<EOF
instance-id: ${VM_NOMBRE}-$(date +%s)
local-hostname: ${VM_NOMBRE}
EOF

    # El user-data puede contener la contraseña: solo lectura/escritura para root
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
        --os-variant "$SO_VARIANT" \
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
    printf '\n'
    info "VM '${VM_NOMBRE}' creada correctamente."
    printf '  Obtener IP : virsh domifaddr %s\n' "$VM_NOMBRE"
    printf '  Conectar   : ssh %s@<IP>   (o %s.%s si resuelve)\n' "$VM_USUARIO" "$VM_NOMBRE" "$DOMINIO"
    printf '  Consola    : virsh console %s\n' "$VM_NOMBRE"
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