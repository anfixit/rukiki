include $(TOPDIR)/rules.mk

PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=anfixit

LUCI_TITLE:=Smart VPN (Rukiki) — simple mode over Nikki
LUCI_DEPENDS:=+luci-base +nikki +ucode +ucode-mod-uci +ucode-mod-fs
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
