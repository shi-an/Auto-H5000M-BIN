#!/bin/bash
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查是否以 root 运行 (编译不应使用 root)
if [ "$(id -u)" -eq 0 ]; then
    echo -e "${RED}❌ 警告: OpenWrt 编译系统不建议以 root 用户运行！${NC}"
    echo "请创建一个普通用户并赋予 sudo 权限后再运行此脚本。"
    read -p "是否强制继续？(y/N): " force_root
    if [[ "$force_root" != "y" && "$force_root" != "Y" ]]; then
        exit 1
    fi
fi

# 获取当前脚本所在目录
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORKSPACE_DIR="$SCRIPT_DIR/workspace"
mkdir -p "$WORKSPACE_DIR"

# 菜单选择
clear
echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       ImmortalWrt 本地构建脚本 (Auto-Build)    ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}"
echo "请选择构建目标设备:"
echo "1. H5000M (MT798x 24.10)"
echo "2. XR30 (MT7981 24.10)"
echo
read -p "请输入选项 [1-2]: " device_choice

case $device_choice in
    1)
        DEVICE_NAME="H5000M"
        REPO_URL="https://github.com/padavanonly/immortalwrt-mt798x-24.10"
        REPO_BRANCH="mt798x-mt799x-6.6-mtwifi"
        CONFIG_URL="https://raw.githubusercontent.com/padavanonly/immortalwrt-mt798x-6.6/refs/heads/mt798x-mt799x-6.6-mtwifi/defconfig/mt7987_mt7992.config"
        EXTRA_CONFIG_FILE="$SCRIPT_DIR/h5000m.extra.config"
        # 默认启用的插件列表 (对应 build.yml 默认值或常用值，此处设为常用的开启)
        # 注意：这里我们默认开启常用插件以便本地构建测试
        PLUGINS_JSON='{
            "enable_adguardhome": "false",
            "enable_openclash": "true",
            "enable_nikki": "true",
            "enable_upnp": "true",
            "enable_vlmcsd": "true",
            "enable_mosdns": "true",
            "enable_dockerman": "true",
            "enable_qmodem_next": "false",
            "enable_qmodem": "true",
            "enable_mwan": "true",
            "enable_homeproxy": "true",
            "enable_adbyby_plus": "true",
            "enable_original_modem": "false",
            "enable_netspeedtest": "true",
            "enable_at_webserver": "true",
            "enable_zerotier": "true",
            "enable_wrtbwmon": "true",
            "enable_watchcat": "true",
            "enable_easytier": "true",
            "enable_lucky": "true",
            "enable_bandix": "true",
            "enable_daed": "true"
        }'
        DISABLED_PKGS=("luci-app-sms-tool-lite" "luci-app-3ginfo-lite")
        ;;
    2)
        DEVICE_NAME="XR30"
        REPO_URL="https://github.com/padavanonly/immortalwrt-mt798x-6.6.git"
        REPO_BRANCH="openwrt-24.10-6.6"
        CONFIG_URL="https://raw.githubusercontent.com/padavanonly/immortalwrt-mt798x-6.6/refs/heads/openwrt-24.10-6.6/defconfig/mt7981-ax3000.config"
        EXTRA_CONFIG_FILE="$SCRIPT_DIR/xr30.extra.config"
        # XR30 默认插件列表
        PLUGINS_JSON='{
            "enable_openclash": "true",
            "enable_netspeedtest": "true",
            "enable_easytier": "true",
            "enable_lucky": "true",
            "enable_bandix": "true"
        }'
        DISABLED_PKGS=("luci-theme-bootstrap-mod" "luci-app-wrtbwmon" "luci-app-eqos-mtk" "luci-i18n-eqos-mtk-zh-cn" "luci-app-sms-tool-lite" "luci-app-3ginfo-lite")
        ;;
    *)
        echo -e "${RED}无效的选项${NC}"
        exit 1
        ;;
esac

echo -e "${GREEN}✅ 已选择: $DEVICE_NAME${NC}"
echo -e "仓库: $REPO_URL ($REPO_BRANCH)"

# 1. 安装依赖
echo -e "\n${YELLOW}>>> [1/7] 检查并安装构建依赖...${NC}"
echo "需要 sudo 权限来安装软件包"
sudo apt-get update -qq
sudo apt-get install -y build-essential git ccache python3 python3-pip \
    libncurses5-dev libssl-dev libgmp3-dev libmbedtls-dev rustc cargo \
    golang-go autoconf automake libtool patch make gcc g++ gawk gettext unzip file wget \
    clang llvm npm jq

# 2. 准备源码
echo -e "\n${YELLOW}>>> [2/7] 准备源码...${NC}"
SOURCE_DIR="$WORKSPACE_DIR/immortalwrt"
if [ ! -d "$SOURCE_DIR" ]; then
    echo "正在克隆源码..."
    git clone -b $REPO_BRANCH --single-branch --depth=1 $REPO_URL "$SOURCE_DIR"
else
    echo "源码目录已存在，检查更新..."
    cd "$SOURCE_DIR"
    git fetch origin $REPO_BRANCH
    git reset --hard FETCH_HEAD
    cd "$WORKSPACE_DIR"
fi

# 3. 生成配置 JSON
echo -e "\n${YELLOW}>>> [3/7] 生成构建配置 (plugins.json)...${NC}"
mkdir -p "$WORKSPACE_DIR/config"
echo "$PLUGINS_JSON" > "$WORKSPACE_DIR/config/plugins.json"
echo "已写入配置到 $WORKSPACE_DIR/config/plugins.json"

# 4. Feeds 处理
echo -e "\n${YELLOW}>>> [4/7] 更新 Feeds...${NC}"
cd "$SOURCE_DIR"
if [ -f "$SCRIPT_DIR/feeds.conf.default" ]; then
    cp "$SCRIPT_DIR/feeds.conf.default" ./feeds.conf.default
fi

# 动态清理 Feeds (使用 Python 逻辑)
python3 -c "
import json, os
try:
    with open('$WORKSPACE_DIR/config/plugins.json') as f:
        data = json.load(f)
        
    # Nikki
    if str(data.get('enable_nikki', False)).lower() != 'true':
        os.system(\"sed -i '/src-git nikki/d' feeds.conf.default\")
        os.system(\"sed -i '/nikki/d' feeds.conf.default\")
        
    # QModem
    qn = str(data.get('enable_qmodem_next', False)).lower() == 'true'
    q = str(data.get('enable_qmodem', False)).lower() == 'true'
    if not qn and not q:
        os.system(\"sed -i '/qmodem/d' feeds.conf.default\")
except Exception as e:
    print(f'Feeds 处理错误: {e}')
"

./scripts/feeds update -a
./scripts/feeds install -a

# 5. 克隆第三方包 & 预下载
echo -e "\n${YELLOW}>>> [5/7] 克隆第三方插件 & 预下载...${NC}"

# 定义一个辅助函数来检查 JSON 配置
is_enabled() {
    local key=$1
    python3 -c "import json; print(str(json.load(open('$WORKSPACE_DIR/config/plugins.json')).get('$key', False)).lower())"
}

# NetSpeedTest
if [ "$(is_enabled 'enable_netspeedtest')" == "true" ] && [ ! -d "package/luci-app-netspeedtest" ]; then
    git clone https://github.com/sirpdboy/luci-app-netspeedtest.git -b master package/luci-app-netspeedtest
fi

# Lucky
if [ "$(is_enabled 'enable_lucky')" == "true" ] && [ ! -d "package/luci-app-lucky" ]; then
    git clone https://github.com/gdy666/luci-app-lucky.git -b main package/luci-app-lucky
fi

# AT WebServer (仅 H5000M)
if [ "$DEVICE_NAME" == "H5000M" ] && [ "$(is_enabled 'enable_at_webserver')" == "true" ] && [ ! -d "package/luci-app-at-webserver" ]; then
    git clone https://github.com/inotdream/mt5700webui-openwrt-server.git -b main package/luci-app-at-webserver
fi

# Daed (仅 H5000M)
if [ "$DEVICE_NAME" == "H5000M" ] && [ "$(is_enabled 'enable_daed')" == "true" ] && [ ! -d "package/dae" ]; then
    git clone https://github.com/QiuSimons/luci-app-daed.git package/dae
    # 需要 sudo 安装 pnpm
    sudo npm install -g pnpm
fi

# 预下载 EasyTier 和 Bandix
INSTALL_DIR="files/root/ipks"
mkdir -p "$INSTALL_DIR"
mkdir -p files/etc/uci-defaults

if [ "$(is_enabled 'enable_easytier')" == "true" ]; then
    echo "正在下载 EasyTier..."
    ET_URL=$(curl -s https://api.github.com/repos/EasyTier/luci-app-easytier/releases/latest | jq -r '.assets[] | select(.name | contains("aarch64_cortex-a53") and (contains("SNAPSHOT") | not)).browser_download_url // empty' | head -1)
    if [ -n "$ET_URL" ]; then
        wget -qO /tmp/easytier.zip "$ET_URL"
        unzip -o /tmp/easytier.zip -d "$INSTALL_DIR/"
    fi
fi

if [ "$(is_enabled 'enable_bandix')" == "true" ]; then
    echo "正在下载 Bandix..."
    BD_CORE_URL=$(curl -s https://api.github.com/repos/timsaya/openwrt-bandix/releases/latest | jq -r '.assets[] | select(.name | contains("bandix") and contains("aarch64_cortex-a53") and contains(".ipk")).browser_download_url // empty' | head -1)
    [ -n "$BD_CORE_URL" ] && wget -P "$INSTALL_DIR/" "$BD_CORE_URL"
    
    BD_LUCI_URL=$(curl -s https://api.github.com/repos/timsaya/luci-app-bandix/releases/latest | jq -r '.assets[] | select(.name | contains("luci-app-bandix") and contains(".ipk")).browser_download_url // empty' | head -1)
    [ -n "$BD_LUCI_URL" ] && wget -P "$INSTALL_DIR/" "$BD_LUCI_URL"
    
    BD_I18N_URL=$(curl -s https://api.github.com/repos/timsaya/luci-app-bandix/releases/latest | jq -r '.assets[] | select(.name | contains("luci-i18n-bandix-zh-cn") and contains(".ipk")).browser_download_url // empty' | head -1)
    [ -n "$BD_I18N_URL" ] && wget -P "$INSTALL_DIR/" "$BD_I18N_URL"
fi

# 创建自动安装脚本
cat > files/etc/uci-defaults/99-install-custom-ipks << 'EOF'
#!/bin/sh
if [ -d "/root/ipks" ]; then
    opkg install /root/ipks/easytier*.ipk
    opkg install /root/ipks/bandix*.ipk
    opkg install /root/ipks/luci-app-*.ipk
    opkg install /root/ipks/luci-i18n-*.ipk
    rm -rf /root/ipks
fi
exit 0
EOF
chmod +x files/etc/uci-defaults/99-install-custom-ipks

# OpenClash 内核预装
if [ "$(is_enabled 'enable_openclash')" == "true" ]; then
    echo "预装 OpenClash 内核..."
    core_path="feeds/luci/applications/luci-app-openclash/root/etc/openclash/core"
    mkdir -p "$core_path"
    wget -qO- https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz | tar xOvz > "$core_path/clash_meta"
    chmod +x "$core_path/clash_meta"
fi

# 修改默认 IP
sed -i 's/192.168.6.1/192.168.88.1/g' package/base-files/files/bin/config_generate

# 6. 生成 .config
echo -e "\n${YELLOW}>>> [6/7] 生成 .config 配置文件...${NC}"
curl -fsSL "$CONFIG_URL" -o base.config || {
    # 如果下载失败，尝试使用本地 default
    if [ -f "defconfig/mt7987_mt7992.config" ]; then cp defconfig/mt7987_mt7992.config base.config; fi
    if [ -f "defconfig/mt7981-ax3000.config" ]; then cp defconfig/mt7981-ax3000.config base.config; fi
}
cat base.config > .config

# 动态添加插件配置 (使用 Python 生成 config 片段)
echo "正在应用插件配置..."
export CFG="$WORKSPACE_DIR/config/plugins.json"
python3 -c '
import json, os, sys

def get_config_lines(key):
    name = key.replace("enable_", "")
    lines = []
    
    # 通用处理
    if name not in ["easytier", "bandix"]:
        lines.append(f"CONFIG_PACKAGE_luci-app-{name}=y")
        
    # 特殊处理
    if name == "nikki":
        lines.extend([
            "CONFIG_PACKAGE_nikki=y",
            "CONFIG_PACKAGE_luci-i18n-nikki-zh-cn=y",
            "CONFIG_PACKAGE_ca-bundle=y",
            "CONFIG_PACKAGE_curl=y",
            "CONFIG_PACKAGE_yq=y",
            "CONFIG_PACKAGE_firewall4=y",
            "CONFIG_PACKAGE_ip-full=y",
            "CONFIG_PACKAGE_kmod-inet-diag=y",
            "CONFIG_PACKAGE_kmod-nft-socket=y",
            "CONFIG_PACKAGE_kmod-nft-tproxy=y",
            "CONFIG_PACKAGE_kmod-tun=y"
        ])
    elif name == "openclash":
        pass # 只需 luci-app-openclash
    elif name == "netspeedtest":
        lines.append("CONFIG_PACKAGE_luci-i18n-netspeedtest-zh-cn=y")
    elif name == "lucky":
        lines.append("CONFIG_PACKAGE_luci-i18n-lucky-zh-cn=y")
    elif name == "adbyby_plus":
        lines.extend([
            "CONFIG_PACKAGE_luci-i18n-adbyby-plus-zh-cn=y",
            "CONFIG_PACKAGE_ipset=y"
        ])
    elif name == "original_modem":
        lines.extend([
            "CONFIG_PACKAGE_modem=y",
            "CONFIG_PACKAGE_luci-i18n-modem-zh-cn=y",
            "# CONFIG_PACKAGE_luci-app-qmodem-next is not set",
            "# CONFIG_PACKAGE_luci-app-qmodem is not set",
            "# CONFIG_PACKAGE_qmodem is not set"
        ])
    elif name == "qmodem":
        lines.extend([
            "CONFIG_PACKAGE_luci-compat=y",
            "CONFIG_PACKAGE_qmodem=y",
            "# CONFIG_PACKAGE_luci-app-qmodem-next is not set",
            "# CONFIG_PACKAGE_luci-app-modem is not set",
            "CONFIG_PACKAGE_luci-app-qmodem_INCLUDE_vendor-qmi-wwan=y",
            "# CONFIG_PACKAGE_luci-app-qmodem_INCLUDE_generic-qmi-wwan is not set",
            "CONFIG_PACKAGE_ndisc6=y",
            "CONFIG_PACKAGE_quectel-CM-5G-M=y",
            "CONFIG_PACKAGE_sms-tool_q=y"
        ])
    elif name == "mwan":
        lines.append("CONFIG_PACKAGE_mwan3=y")
    elif name == "zerotier":
        lines.extend(["CONFIG_PACKAGE_zerotier=y", "CONFIG_PACKAGE_luci-i18n-zerotier-zh-cn=y"])
    
    return lines

try:
    with open(os.environ["CFG"]) as f:
        data = json.load(f)
        for k, v in data.items():
            if k.startswith("enable_") and str(v).lower() == "true":
                for line in get_config_lines(k):
                    print(line)
except Exception as e:
    print(f"# Config Gen Error: {e}")
' >> .config

# 应用额外配置
if [ -f "$EXTRA_CONFIG_FILE" ]; then
    echo "应用额外配置文件: $(basename $EXTRA_CONFIG_FILE)"
    cat "$EXTRA_CONFIG_FILE" >> .config
fi

# 应用禁用列表
for pkg in "${DISABLED_PKGS[@]}"; do
    sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
    echo "# CONFIG_PACKAGE_${pkg} is not set" >> .config
done

make defconfig

# 7. 开始编译
echo -e "\n${YELLOW}>>> [7/7] 开始编译...${NC}"
echo "下载依赖包..."
make download -j$(nproc) || make download -j1 V=s

echo "开始多线程编译 (使用 $(nproc) 线程)..."
make -j$(nproc) || {
    echo -e "${RED}编译失败！尝试单线程详细输出...${NC}"
    make -j1 V=s
}

echo -e "${GREEN}✅ 编译完成！${NC}"
echo "产物目录: $SOURCE_DIR/bin/targets"
