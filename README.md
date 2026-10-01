# script_creacion_rapida_vm

## Script para crear rapidamente maquinas virtuales  partir de imagenes cloud init en kvm usando virt-install

### Para usar:

- Cambiar el catalogo incluido por tus plantillas y sus rutas (o si deseas usar las opciones predefinidas del catalogo, cambiar las rutas de sus imagenes en cada entrada del catalo). Las instrucciones se encuentran en el interior

- Agregar tu clave publica al script en la cariable CLAVE_PUBLICA_SSH

- Configurar otras variables de usuario, como las rutas de las imagenes, el nombre de dominio o la red en la que quieres crear las maquinas.

- Colocar el script en tu directorio deseado y darle permiso de ejecucion

### ¡¡¡IMPORTANTE!!! 

- El script fue hecho en su mayoria por claude, asi que es posible que pueda haber errores que no haya encontrado aun.

- Como fue creado para operar sobre /var/lib/libvirt/images es necesario ejecutarlo con sudo o como root
