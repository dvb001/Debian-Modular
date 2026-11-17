#!/bin/bash
# ==========================================================
# Debian 12 多模块 Live 系统构建脚本 (带 Apt 记录继承与排重机制)
# 模块结构:
#   - 001-base.squashfs			: 基础系统 + 核心内核 + 用户(debian)
#   - 002-devtools.squashfs		: Python / Go / Rust / 工具链
#   - 003-xorg.squashfs			: 桌面基础包 xserver / lightdm 桌面共用包等
#   - 004-gui.squashfs			: 桌面 Xfce mate 等可选
# ==========================================================

# 默认桌面
SET_DESKTOPS="${GUI_DESKTOPS:-mate xfce}"
# 默认版本
SET_VERSION="${TARGET_VERSION:-bookworm}"
# overlay 挂载命令
MOUNT_OVERLAY_CMD="fuse-overlayfs"

set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] 请使用 sudo 或 root 权限运行此脚本。"
  exit 1
fi

WORK_DIR="$PWD/target"
BASE_ROOT="$WORK_DIR/001-base"
DEV_ROOT="$WORK_DIR/002-dev"
XORG_ROOT="$WORK_DIR/003-xorg"
GUI_ROOT="$WORK_DIR/004-gui"
OTHER_ROOT="$WORK_DIR/005-other"

BASE_CHROOT="$BASE_ROOT/chroot"
DEV_CHROOT="$DEV_ROOT/chroot"
XORG_CHROOT="$XORG_ROOT/chroot"
GUI_CHROOT="$GUI_ROOT/chroot"
OTHER_CHROOT="$TOOLS_ROOT/chroot"

DEV_STAGE="$DEV_ROOT/stage"
XORG_STAGE="$XORG_ROOT/stage"
GUI_STAGE="$GUI_ROOT/stage"
OTHER_STAGE="$TOOLS_ROOT/stage"

DEV_WORK="$DEV_ROOT/work"
XORG_WORK="$XORG_ROOT/work"
GUI_WORK="$GUI_ROOT/work"
OTHER_WORK="$TOOLS_ROOT/work"

ISO_DIR="$WORK_DIR/iso"
OUTPUT_ISO="$WORK_DIR/debian-$SET_VERSION-modular.iso"

mount_chroot() {
    mount -t proc proc "$1/proc"
    mount -t sysfs sysfs "$1/sys"
    mount --bind /dev "$1/dev"
    mount --bind /dev/pts "$1/dev/pts"
}
umount_chroot() {
    umount "$1/proc" || true
    umount "$1/sys" || true
    umount "$1/dev/pts" || true
    umount "$1/dev" || true
    umount "$1" 2>/dev/null || true
}

cp_initramfs() {
    echo $1
    for file in "$1/boot/"initrd.img-*; do
        # 确保文件真实存在（防止路径下没有匹配项时把通配符本身当成文件名）
        if [ -f "$file" ]; then
            echo "复制 initramfs 到 ISO ..."
            cp -v "$file" "$ISO_DIR/boot/initrd.img"
            rm "$file"
        fi
    done
}

step_prep() {
    echo "[+] Install basic packages..."
    apt update
    apt install -y debootstrap squashfs-tools initramfs-tools \
	    isolinux dosfstools syslinux-utils xorriso rsync \
	    grub-pc-bin grub-efi-amd64-bin
}

rm_stage_temps() {
    rm -f "$1/etc/passwd" "$1/etc/shadow" "$1/etc/group" \
          "$1/etc/gshadow" "$1/etc/machine-id" "$1/etc/hostname" \
          "$1/etc/hosts"
}

step_base() {
	echo "目标版本：$SET_VERSION"
	sleep 1
    echo "[+] 步骤 1/5: 构建基础系统 (001-base)..."
    
    mkdir -p "$BASE_CHROOT" "$ISO_DIR/live" "$ISO_DIR/boot" "$ISO_DIR/isolinux"

    if [ ! -f "$BASE_CHROOT/bin/bash" ]; then
        debootstrap --arch=amd64 "$SET_VERSION" "$BASE_CHROOT" http://deb.debian.org/debian
    fi
	COMPONENTS="main contrib non-free non-free-firmware"	
	# 3. 写入 sources.list
	cat <<EOF > "$BASE_CHROOT/etc/apt/sources.list"
deb http://deb.debian.org/debian $SET_VERSION $COMPONENTS
deb http://deb.debian.org/debian-security $SET_VERSION-security $COMPONENTS
EOF

    echo "[*] 在 Base 中安装内核、基础服务并创建用户 debian..."
    umount_chroot "$BASE_CHROOT" || true
    mount_chroot "$BASE_CHROOT"
    chroot "$BASE_CHROOT" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt update && \
        apt install -y linux-image-amd64 live-boot initramfs-tools \
			fuse3 ntfs-3g squashfs-tools \
			systemd-sysv network-manager sudo && \
        echo 'debian' > /etc/hostname && \
        grep -q '127.0.0.1.*debian' /etc/hosts || echo '127.0.0.1   debian' >> /etc/hosts && \
        id debian &>/dev/null || useradd -m -s /bin/bash debian && \
        echo 'debian:toor' | chpasswd && \
        usermod -aG sudo,adm,dialout,cdrom,floppy,audio,dip,video,plugdev debian && \
        apt clean
    "
    patch_block_mount() {
        echo "[*] Patch base..."
        cp -R ./data/patch/* "$BASE_CHROOT/"
        chroot "$BASE_CHROOT" /bin/bash -c '
		    KERNEL_VERSION=$(ls /lib/modules 2>/dev/null | head -n 1 | tr -d "[:space:]")
		    if [ -z "$KERNEL_VERSION" ]; then
		        KERNEL_VERSION="all"
		    fi    
		    echo "[*] 检测到的目标内核版本: $KERNEL_VERSION"
		    if [ -f "/usr/sbin/update-initramfs.orig.initramfs-tools" ]; then
		        update-initramfs.orig.initramfs-tools -u -k "$KERNEL_VERSION"
		    else
		        update-initramfs -u -k "$KERNEL_VERSION"
		    fi
		    systemctl enable fix-dpkg-status.service
		'
    }
    patch_block_mount || true

    cp_initramfs "$BASE_CHROOT"

    umount_chroot "$BASE_CHROOT" || true
    echo "[*] 打包 001-base.squashfs..."
    rm "$ISO_DIR/live/001-base.squashfs" 2>/dev/null || true
    mksquashfs "$BASE_CHROOT" "$ISO_DIR/live/001-base.squashfs" -comp xz
    echo "[+] 001-base 构建完成！"
}

step_dev() {
    echo "[+] 步骤 2/5: 构建 DevTools 开发工具增量模块 (002-devtools)..."

    # 创建必要的挂载目录和工作目录
    umount_chroot "$DEV_CHROOT"
    read -p "Remove last stage? [y/N]" choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "删除历史记录..."
        rm -rf "$DEV_ROOT"
    fi
    mkdir -p "$DEV_CHROOT" "$DEV_STAGE" "$DEV_WORK"

    echo "[*] mountting overlay systems..."
    # 使用 overlay 挂载
    $MOUNT_OVERLAY_CMD \
        -o lowerdir="$BASE_CHROOT",upperdir="$DEV_STAGE",workdir="$DEV_WORK" \
        "$DEV_CHROOT"
    mount_chroot "$DEV_CHROOT"
    echo "[*] 正在从 Base 系统获取内核版本..."
    KERNEL_FILE=$(find "$BASE_CHROOT/boot" -maxdepth 1 -name "vmlinuz-*" | head -n 1)
    if [ -z "$KERNEL_FILE" ]; then
        echo "[-] 错误: 请先构建 base 模块 (step_prep)，未在 Base 中找到内核！"
        exit 1
    fi
    KERNEL_VERSION=$(basename "$KERNEL_FILE" | sed 's/vmlinuz-//')
    echo "[+] 检测到目标内核版本: $KERNEL_VERSION"

    echo "[*] 在 Dev Chroot 中安装开发工具链..."
    chroot "$DEV_CHROOT" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt install -y --no-install-recommends \
            build-essential git curl wget vim htop cmake pkg-config \
            linux-headers-amd64 unzip gawk gpg \
            python3 python3-pip python3-venv golang rustc cargo || true \

        echo '[*] 正在创建软链接以适配目标内核版本: $KERNEL_VERSION'

        INSTALLED_HEADER=\$(ls -d /usr/src/linux-headers-*-amd64 2>/dev/null | head -n 1)
        INSTALLED_COMMON=\$(ls -d /usr/src/linux-headers-*-common 2>/dev/null | head -n 1)

        if [ -n \"\$INSTALLED_HEADER\" ]; then
            TARGET_HEADER_DIR=\"/usr/src/linux-headers-$KERNEL_VERSION\"
            if [ ! -e \"\$TARGET_HEADER_DIR\" ]; then
                ln -sfn \"\$INSTALLED_HEADER\" \"\$TARGET_HEADER_DIR\"
                echo \"[+] 已创建头文件架构目录软链接: \$TARGET_HEADER_DIR -> \$INSTALLED_HEADER\"
            fi
        fi

        if [ -n \"\$INSTALLED_COMMON\" ]; then
            BASE_VER=\$(echo $KERNEL_VERSION | sed 's/-amd64//')
            TARGET_COMMON_DIR=\"/usr/src/linux-headers-\$BASE_VER-common\"
            if [ ! -e \"\$TARGET_COMMON_DIR\" ]; then
                ln -sfn \"\$INSTALLED_COMMON\" \"\$TARGET_COMMON_DIR\"
                echo \"[+] 已创建通用头文件目录软链接: \$TARGET_COMMON_DIR -> \$INSTALLED_COMMON\"
            fi
        fi

        MODULE_DIR=\"/lib/modules/$KERNEL_VERSION\"
        mkdir -p \"\$MODULE_DIR\"
        if [ -d \"/usr/src/linux-headers-$KERNEL_VERSION\" ]; then
            ln -sfn \"/usr/src/linux-headers-$KERNEL_VERSION\" \"\$MODULE_DIR/build\"
            echo '[+] 已绑定 /lib/modules/$KERNEL_VERSION/build 软链接'
        elif [ -n \"\$INSTALLED_HEADER\" ]; then
            ln -sfn \"\$INSTALLED_HEADER\" \"\$MODULE_DIR/build\"
            echo '[+] 已绑定 /lib/modules/$KERNEL_VERSION/build 软链接到实际目录'
        fi

        echo '[+] 软链接构建完成！'
        apt clean
    "
    sleep 2
    umount_chroot "$DEV_CHROOT"
    #rm_stage_temps "$DEV_STAGE"
    
    # 3. 打包排重后的增量模块
    echo "[*] 打包 002-devtools.squashfs..."
    rm "$ISO_DIR/live/002-devtools.squashfs" 2>/dev/null || true
    mksquashfs "$DEV_STAGE" "$ISO_DIR/live/002-devtools.squashfs" -comp xz
    echo "[+] 002-devtools 增量模块构建完成！"
}

step_xorg() {
    echo "[+] 步骤 3/5: 构建 XORG 桌面环境模块 (003-xorg)..."

    # 创建必要的挂载目录和工作目录
    echo "[*] mountting overlay systems..."
    umount "$XORG_CHROOT" || true
    read -p "Remove last stage? [y/N]" choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "删除历史记录..."
        rm -rf "$XORG_ROOT"
    fi
    mkdir -p "$XORG_CHROOT" "$XORG_STAGE" "$XORG_WORK"

    # 使用 overlay 挂载
    $MOUNT_OVERLAY_CMD \
        -o lowerdir="$DEV_STAGE:$BASE_CHROOT",upperdir="$XORG_STAGE",workdir="$XORG_WORK" \
        "$XORG_CHROOT"
	mount_chroot "$XORG_CHROOT"
    echo "[*] 在 XORG Chroot 中安装 xorg 及相关软件..."
    chroot "$XORG_CHROOT" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt install -y --no-install-recommends \
            lightdm xserver-xorg xserver-xorg-core \
            xinit x11-xserver-utils im-config \
            libnotify-bin desktop-base \
            fcitx5 fcitx5-config-qt fcitx5-chinese-addons \
            fcitx5-frontend-qt5 fcitx-frontend-gtk3 \
            pluma pluma-plugins engrampa gnome-terminal \
            font-viewer libwebkit2gtk-4.1-0 \
            gvfs-backends gvfs-fuse caja \
            pulseaudio pavucontrol \
            firefox-esr \
            gparted mesa-utils network-manager-gnome && \
        apt clean
    "
    # fonts-noto-cjk fonts-noto-cjk-extra

    sleep 2
    umount "$XORG_CHROOT" || true
    
    cp_initramfs "$XORG_STAGE"
    # 3. 打包排重后的增量模块
    echo "[*] 打包 003-xorg.squashfs..."
    rm "$ISO_DIR/live/003-xorg.squashfs" 2>/dev/null || true
    mksquashfs "$XORG_STAGE" "$ISO_DIR/live/003-xorg.squashfs" -comp xz
    echo "[+] 003-xorg 增量模块构建完成！"
}

step_gui() {
    # 如果没有传入参数，默认使用 mate
    if [ $# -eq 0 ]; then
        set -- mate
    fi
    
    local pkg_list=""
    local desktop_desc=""
    
    # 遍历所有传入的桌面类型参数
    for desktop_type in "$@"; do
        case "$desktop_type" in
            mate)
                pkg_list="$pkg_list mate-desktop-environment-core eom"
                ;;
            xfce)
                pkg_list="$pkg_list xfce4 xfce4-goodies"
                ;;
            lxqt)
                pkg_list="$pkg_list lxqt lxqt-themes breeze-gtk-theme breeze-icon-theme"
                ;;
            kde)
                pkg_list="$pkg_list kde-plasma-desktop"
                ;;
            lxde)
                pkg_list="$pkg_list lxde"
                ;;
            cinnamon)
                pkg_list="$pkg_list cinnamon cinnamon-control-center"
                ;;
            *)
                echo "[-] 错误: 未知的桌面类型 '$desktop_type' (支持: mate, xfce, lxqt, kde, lxde, cinnamon)"
                return 1
                ;;
        esac
        desktop_desc="${desktop_desc} ${desktop_type}"
    done

    # 固定模块名与目录名，不随参数拼接
    local module_name="004-gui.squashfs"
    local multi_chroot="${GUI_CHROOT}"
    local multi_stage="${GUI_STAGE}"
    local multi_work="${GUI_WORK}"

    echo "[+] 步骤: 构建统一的 GUI 桌面环境模块 (包含:${desktop_desc})..."
    echo "[*] 包含的软件包列表: $pkg_list"

    # 创建必要的挂载目录和工作目录
    echo "[*] mounting overlay systems..."
    umount_chroot "$multi_chroot" || true
    read -p "Remove last stage for gui? [y/N] " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "删除历史记录..."
        rm -rf "$GUI_ROOT"
    fi
    mkdir -p "$multi_chroot" "$multi_stage" "$multi_work"

    # 使用 overlay 挂载
    $MOUNT_OVERLAY_CMD \
        -o lowerdir="$XORG_STAGE:$DEV_STAGE:$BASE_CHROOT",upperdir="$multi_stage",workdir="$multi_work" \
        "$multi_chroot"
    mount_chroot "$multi_chroot"

    echo "[*] 在 GUI Chroot 中统一安装所选桌面及相关软件..."
    chroot "$multi_chroot" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt update && \
        apt install -y --no-install-recommends \
            $pkg_list \
            && \
        apt clean
    "
    sleep 2
    umount_chroot "$multi_chroot" || true
    
    # 打包成固定的 004-gui.squashfs 模块
    echo "[*] 打包 $module_name..."
    rm "$ISO_DIR/live/$module_name" 2>/dev/null || true
    mksquashfs "$multi_stage" "$ISO_DIR/live/$module_name" -comp xz
    echo "[+] 统一 GUI 模块 ($module_name) 构建完成！"
}

make_uefi_boot() {
    # 1. 创建一个 4MB 的空白 FAT 镜像
    mkdir -p "$ISO_DIR/boot/grub"
    dd if=/dev/zero of="$ISO_DIR/boot/grub/efiboot.img" bs=1M count=32
    mkfs.vfat "$ISO_DIR/boot/grub/efiboot.img"

    # 2. 挂载镜像
    mkdir -p /tmp/efi_install
    mount -o loop "$ISO_DIR/boot/grub/efiboot.img" /tmp/efi_install

    # 3. 使用宿主机的 grub-install 直接将 GRUB 安装到这个挂载点中
    # 这样会自动生成 EFI/BOOT/BOOTX64.EFI 以及所需的全部核心模块
    grub-install --target=x86_64-efi \
                --efi-directory=/tmp/efi_install \
                --boot-directory=/tmp/efi_install/boot \
                --removable \
                --no-floppy \
                --modules="normal part_gpt part_msdos fat search iso9660 linux"

    umount /tmp/efi_install
    rm -rf /tmp/efi_install

    cat << 'EOF' > "$ISO_DIR/boot/grub/grub.cfg"
set timeout=50
set default=0

menuentry "Start Debian 12 Modular (UEFI)" {
    search --no-floppy --set=root --file /boot/vmlinuz
    linux /boot/vmlinuz boot=live components splash
    initrd /boot/initrd.img
}

menuentry "Start Debian 12 Modular (persistence) (UEFI)" {
    search --no-floppy --set=root --file /boot/vmlinuz
    linux /boot/vmlinuz boot=live persistence persistence-label=ldata components splash
    initrd /boot/initrd.img
}
EOF
}

make_iso_boot() {
    cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
    cp /usr/lib/syslinux/modules/bios/*.c32 "$ISO_DIR/isolinux/"

    cat <<EOF > "$ISO_DIR/isolinux/isolinux.cfg"
UI menu.c32
PROMPT 0
TIMEOUT 50

LABEL debian-modular
    MENU LABEL Start Debian 12 Modular
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img boot=live components splash
LABEL debian-modular-with-persistence
    MENU LABEL Start Debian 12 Modular (persistence) 
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img boot=live persistence persistence-label=ldata components splash
EOF
}

step_boot() {
    echo "[+] ISO: 提取内核、配置引导并生成双启动 ISO (BIOS + UEFI)..."

    KERNEL_FILE=$(find "$BASE_CHROOT/boot" -maxdepth 1 -name "vmlinuz-*" | head -n 1)
    if [ -z "$KERNEL_FILE" ]; then
        echo "[-] 错误: 未能在 $BASE_CHROOT/boot 中找到内核！"
        exit 1
    fi
    
    KERNEL_VER=$(basename "$KERNEL_FILE" | sed 's/vmlinuz-//')
    echo "[*] 检测到内核版本: $KERNEL_VER"

    [ -f ./data/install.sh ] && cp ./data/install.sh "$ISO_DIR/"
    cp "$BASE_CHROOT/boot/vmlinuz-$KERNEL_VER" "$ISO_DIR/boot/vmlinuz"

    make_uefi_boot
    make_iso_boot
    
    echo "[*] 正在生成支持 BIOS 与 UEFI 的混合 ISO 镜像: $OUTPUT_ISO"
    
    # 2. 在 xorriso 中加入 UEFI 引导参数 (-eltorito-alt-boot 及之后的参数)
    xorriso -as mkisofs \
        -iso-level 3 \
        -volid "DEBIAN_MODULAR" \
        -eltorito-boot isolinux/isolinux.bin \
        -eltorito-catalog isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -eltorito-alt-boot \
        -e boot/grub/efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -output "$OUTPUT_ISO" \
        "$ISO_DIR"

    echo "[+] 制作成功！双启动 ISO 镜像路径: $OUTPUT_ISO"
}

case "${1:-}" in
    prep)
        step_prep
        ;;
    base)
        step_base
        ;;
    xorg)
        step_xorg
        ;;
    dev)
        step_dev
        ;;
    gui)
        step_gui $SET_DESKTOPS
        ;;
    boot)
        step_boot
        ;;
    all)
        step_prep
        step_base
        step_dev
        step_xorg
        step_gui $SET_DESKTOPS
        step_boot
        ;;
    *)
        echo "用法: $0 {prep|xorg|dev|gui|boot|all}"
        exit 1
        ;;
esac
