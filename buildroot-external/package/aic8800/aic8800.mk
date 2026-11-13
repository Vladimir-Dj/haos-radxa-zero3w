################################################################################
#
# aic8800 - AICsemi AIC8800 SDIO WiFi driver (Radxa packaging)
#
################################################################################

AIC8800_VERSION = 5562c254b0231be34588dc608ec28c4f1d613285
AIC8800_SITE = $(call github,radxa-pkg,aic8800,$(AIC8800_VERSION))
AIC8800_LICENSE = GPL-2.0
AIC8800_LICENSE_FILES = debian/copyright

AIC8800_MODULE_SUBDIRS = src/SDIO/driver_fw/driver/aic8800
# The BT low-power module only matches Allwinner device trees.
AIC8800_MODULE_MAKE_OPTS = CONFIG_AIC8800_BTLPM_SUPPORT=n

# Radxa keeps its kernel compatibility and firmware path fixes as a quilt
# series in debian/patches - apply it the same way the Debian package does.
# Two files are stored with CRLF line endings; Radxa runs dos2unix on them
# before applying the series (see .github/local/Makefile.local upstream).
AIC8800_CRLF_FILES = \
	src/USB/driver_fw/drivers/aic8800/aic_load_fw/aicbluetooth.c \
	src/USB/driver_fw/drivers/aic8800/aic_load_fw/aic_bluetooth_main.c

define AIC8800_APPLY_DEBIAN_PATCHES
	cd $(@D) && sed -i 's/\r$$//' $(AIC8800_CRLF_FILES)
	while read -r p _; do \
		case "$$p" in ''|\#*) continue ;; esac; \
		echo "Applying debian/patches/$$p"; \
		patch -d $(@D) -p1 -N --no-backup-if-mismatch \
			< $(@D)/debian/patches/$$p || exit 1; \
	done < $(@D)/debian/patches/series
endef
AIC8800_POST_PATCH_HOOKS += AIC8800_APPLY_DEBIAN_PATCHES

# The driver reads firmware directly from /lib/firmware/aic8800_fw/SDIO/<chip>
define AIC8800_INSTALL_FIRMWARE
	mkdir -p $(TARGET_DIR)/lib/firmware/aic8800_fw/SDIO
	for d in $(@D)/src/SDIO/driver_fw/fw/*/; do \
		cp -a "$$d" $(TARGET_DIR)/lib/firmware/aic8800_fw/SDIO/ || exit 1; \
	done
	$(INSTALL) -D -m 0644 $(AIC8800_PKGDIR)/aic8800.conf \
		$(TARGET_DIR)/usr/lib/modules-load.d/aic8800.conf
endef
AIC8800_POST_INSTALL_TARGET_HOOKS += AIC8800_INSTALL_FIRMWARE

$(eval $(kernel-module))
$(eval $(generic-package))
