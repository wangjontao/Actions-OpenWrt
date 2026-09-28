define Device/aigo_ags21
  DEVICE_VENDOR := Aigo
  DEVICE_MODEL := AGS21
  DEVICE_DTS := mt7981b-aigo-ags21
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := automount coremark blkid blockdev fdisk f2fsck mkf2fs kmod-mmc mmc-utils
  KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += aigo_ags21

define Device/newland_nl-wr8103
  DEVICE_VENDOR := Newland
  DEVICE_MODEL := NL-WR8103
  DEVICE_DTS := mt7981b-newland-nl-wr8103
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES :=
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 116736k
  KERNEL_IN_UBI := 1  
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += newland_nl-wr8103

define Device/newland_nl-wr9103
  DEVICE_VENDOR := Newland
  DEVICE_MODEL := NL-WR9103
  DEVICE_DTS := mt7981b-newland-nl-wr9103
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES :=
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 116736k
  KERNEL_IN_UBI := 1
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += newland_nl-wr9103
