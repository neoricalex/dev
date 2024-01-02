#!/bin/bash

echo "Checkando se a $NFDOS_ROOT existe"
if [ ! -d "$NFDOS_ROOT" ]; then
    mkdir -p $NFDOS_ROOT
else
    echo "A $NFDOS_ROOT existe"
fi

echo "Checkando se a $NFDOS_DISCO existe"
if [ ! -f "$NFDOS_DISCO" ]; then
    echo "Criando a $NFDOS_DISCO. Aguarde por favor..."
    sudo dd if=/dev/zero of=$NFDOS_DISCO count=1024 bs=10485760
    echo "Formatando a $NFDOS_DISCO"
    sudo mkfs -t ext4 $NFDOS_DISCO
else
    echo "A $NFDOS_DISCO existe"
fi

echo "Checkando se a $NFDOS_ROOTFS existe"
if [ ! -d "$NFDOS_ROOTFS" ]; then
    echo "Criando a $NFDOS_ROOTFS..."
    mkdir -p $NFDOS_ROOTFS
else
    echo "A $NFDOS_ROOTFS existe"
fi

echo "Checkando se a $NFDOS_ROOTFS está montada"
if grep -qs "$NFDOS_ROOTFS" /proc/mounts; then
    echo "A $NFDOS_ROOTFS está montada."
else
    sudo mount -t auto -o loop $NFDOS_DISCO $NFDOS_ROOTFS  
fi

echo "Checkando se o ROOTFS existe"
if [ ! -d "$NFDOS_ROOTFS/root" ]; then
    echo "Criando o ROOTFS"
    sudo debootstrap --arch=amd64 --variant=minbase focal $NFDOS_ROOTFS
else
    echo "O ROOTFS existe"
fi

echo "Montar a /dev e /run"
sudo mount --bind /dev $NFDOS_ROOTFS/dev
sudo mount --bind /run $NFDOS_ROOTFS/run

echo "Copiar arquivos necessários"
sudo cp $NFDOS_ROOT/rootfs_head.nfdos $NFDOS_ROOTFS/.
sudo cp $NFDOS_ROOT/rootfs_footer.nfdos $NFDOS_ROOTFS/.
sudo cp $NFDOS_ROOT/preseed.cfg $NFDOS_ROOTFS/.
#sudo cp -a $NFDOS_ROOT/neoricalex $NFDOS_ROOTFS/opt
sudo cp $NFDOS_ROOT/no-boot.sh $NFDOS_ROOTFS/usr/local/bin/
sudo cp $NFDOS_ROOT/boot.service $NFDOS_ROOTFS/etc/systemd/system/

echo "Entrar no $NFDOS_ROOTFS e executar o rootfs_head.nfdos"
sudo chroot $NFDOS_ROOTFS /bin/bash rootfs_head.nfdos

#echo "Entrar no $NFDOS_ROOTFS de forma manual"
#sudo chroot $NFDOS_ROOTFS /bin/bash

echo "Entrar no $NFDOS_ROOTFS e executar o rootfs_footer.nfdos"
sudo chroot $NFDOS_ROOTFS /bin/bash rootfs_footer.nfdos

echo "Remover o rootfs_*.nfdos do $NFDOS_ROOTFS"
sudo rm -rf $NFDOS_ROOTFS/rootfs_head.nfdos
sudo rm -rf $NFDOS_ROOTFS/rootfs_footer.nfdos

echo "OK. Neste ponto a nossa imagem de disco (nfdos.img) está criada."
echo "Agora vamos criar uma imagem de CD/DVD para que possamos rodar ela em qualquer Computador/VPS/VM/Etc"
echo "# INFO: Vai aparecer vários \"Unrecognised xattr prefix system.posix_acl_access\" mas não é nada de preocupante :-)"
sleep 5

echo "Criar imagem de CD/DVD (nfdos.iso)"
cd $NFDOS_ROOT
sudo chmod +x cdrom.nfdos
sudo bash cdrom.nfdos

echo "Desmontar a /dev e /run"
sudo umount -lf $NFDOS_ROOTFS/dev
sudo umount -lf $NFDOS_ROOTFS/run

echo "Desmontar o $NFDOS_ROOTFS"
sudo umount -lf $NFDOS_ROOTFS

echo "Limpando..."
sudo rm -rf $NFDOS_DISCO
sudo rm -rf $NFDOS_ROOTFS
sudo rm -rf $NFDOS_ROOT/image
sudo apt autoremove -y

cd $NEORICALEX_HOME