#!/bin/bash

# ============================================
# Script de Criação de VM para Proxmox VE
# Autor: Assistente de Automação
# Versão: 3.0
# ============================================

# --- Variáveis Iniciais e Funções ---

# Cores para o terminal
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# URL para download do VirtIO
VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.271-1/virtio-win-0.1.271.iso"

# Função para exibir erro e sair
error_exit() {
    echo -e "${RED}Erro: $1${NC}" >&2
    exit 1
}

# Função para listar ISOs numeradas
list_isos_numbered() {
    local storage=$1
    local iso_list
    
    # Use 'awk' para imprimir a primeira coluna ($1), que contém o caminho completo da ISO.
    # Em seguida, use 'sed' para remover a parte 'local-btrfs:iso/' do início da linha.
    iso_list=$(pvesm list "$storage" --content iso 2>/dev/null | awk 'NR>1 {print $1}' | sed "s|^$storage/iso/||" | grep "\.iso$")
    
    if [[ -z "$iso_list" ]]; then
        echo -e "${YELLOW}Nenhuma ISO encontrada no storage '$storage'${NC}"
        return 1
    fi

    echo -e "${CYAN}ISOs disponíveis em '$storage':${NC}"
    local counter=1
    while read -r iso; do
        iso_name=$(basename "$iso")
        echo "  ${counter}) ${iso_name}"
        ((counter++))
    done <<< "$iso_list"

    return 0
}

# Função para obter o caminho da ISO selecionada
get_iso_path() {
    local storage=$1
    local iso_number=$2
    
    local iso_file=$(pvesm list "$storage" --content iso 2>/dev/null | awk 'NR>1 {print $NF}' | grep "\.iso$" | sed -n "${iso_number}p")
    
    if [[ -n "$iso_file" ]]; then
        echo "$iso_file"
    fi
}


# Função para baixar VirtIO ISO
download_virtio_iso() {
    local storage=$1
    local storage_path="/var/lib/vz/template/iso"
    
    # Obter o caminho real do storage
    if [[ "$storage" != "local" ]]; then
        storage_path=$(pvesm path "${storage}:iso/dummy.iso" 2>/dev/null | sed 's|/dummy.iso||')
    fi
    
    local virtio_filename="virtio-win-0.1.271.iso"
    local target_path="${storage_path}/${virtio_filename}"
    
    echo -e "${YELLOW}ISO VirtIO não encontrada. Baixando...${NC}"
    echo -e "${CYAN}URL: ${VIRTIO_URL}${NC}"
    
    # Criar diretório se não existir
    mkdir -p "$storage_path" 2>/dev/null || {
        echo -e "${RED}Erro: Não foi possível criar o diretório de ISOs${NC}"
        return 1
    }
    
    # Baixar com wget
    if command -v wget &> /dev/null; then
        wget -q --show-progress -O "$target_path" "$VIRTIO_URL"
    elif command -v curl &> /dev/null; then
        curl -L -o "$target_path" "$VIRTIO_URL"
    else
        echo -e "${RED}Erro: wget ou curl não encontrados${NC}"
        return 1
    fi
    
    if [[ -f "$target_path" ]]; then
        echo -e "${GREEN}ISO VirtIO baixada com sucesso!${NC}"
        # Atualizar o storage para reconhecer a nova ISO
        pvesm scan "$storage" 2>/dev/null
        return 0
    else
        echo -e "${RED}Erro ao baixar ISO VirtIO${NC}"
        return 1
    fi
}

# Função para encontrar o storage principal
find_main_storage() {
    pvesm status | awk '$2 ~ /^(dir|lvmthin|btrfs)$/ && $3 ~ /(active|available)/ {print $1; exit}'
}

# Função para obter próximo ID disponível
get_next_vmid() {
    local max_id=0
    for id in $(qm list 2>/dev/null | tail -n +2 | awk '{print $1}'); do
        if [[ $id -gt $max_id ]]; then
            max_id=$id
        fi
    done
    echo $((max_id + 1))
}

# Função para validar entrada numérica
validate_number() {
    if ! [[ "$1" =~ ^[0-9]+$ ]]; then
        error_exit "Valor inválido: $1. Por favor, insira um número."
    fi
}

# Função para listar bridges numeradas
list_bridges_numbered() {
    local bridges=()
    
    # Tentar primeiro método - bridges tipo bridge
    while IFS= read -r bridge; do
        if [[ ! -z "$bridge" ]] && [[ "$bridge" == vmbr* ]]; then
            bridges+=("$bridge")
        fi
    done < <(ip link show type bridge 2>/dev/null | grep -E "^[0-9]+:" | awk '{print $2}' | sed 's/://')
    
    # Se não encontrou, tentar método alternativo
    if [[ ${#bridges[@]} -eq 0 ]]; then
        while IFS= read -r bridge; do
            if [[ ! -z "$bridge" ]]; then
                bridges+=("$bridge")
            fi
        done < <(ip addr show 2>/dev/null | grep -E "^[0-9]+: vmbr" | awk '{print $2}' | sed 's/://')
    fi
    
    # Se ainda não encontrou, adicionar vmbr0 como padrão
    if [[ ${#bridges[@]} -eq 0 ]]; then
        bridges=("vmbr0")
    fi
    
    echo -e "${CYAN}Bridges de rede disponíveis:${NC}"
    for i in "${!bridges[@]}"; do
        local bridge_info=""
        # Tentar obter informações adicionais da bridge
        local ip_info=$(ip addr show "${bridges[$i]}" 2>/dev/null | grep "inet " | head -1 | awk '{print $2}')
        if [[ ! -z "$ip_info" ]]; then
            bridge_info=" (IP: $ip_info)"
        fi
        echo "  $((i+1))) ${bridges[$i]}${bridge_info}"
    done
    
    # Retornar array como string
    echo "BRIDGES:${bridges[@]}"
}

# Função para obter bridge selecionada
get_selected_bridge() {
    local bridge_data="$1"
    local selection=$2
    
    # Extrair apenas a parte das bridges
    local bridges_str="${bridge_data#*BRIDGES:}"
    IFS=' ' read -ra bridges <<< "$bridges_str"
    
    if [[ $selection -ge 1 && $selection -le ${#bridges[@]} ]]; then
        echo "${bridges[$((selection-1))]}"
    else
        echo "${bridges[0]}"
    fi
}

# Função que retorna storages ativos
get_active_storages() {
    mapfile -t storages < <(pvesm status | awk '$3 ~ /(active|available)/ {print $1}')
    echo "${storages[@]}"
}

# Função que valida o storage para ISO
get_iso_storage() {
    local active_storages=($(get_active_storages))
    
    # Se só tiver um ativo, usa ele
    if [ "${#active_storages[@]}" -eq 1 ]; then
        echo "${active_storages[0]}"
        return
    fi

    # Se houver mais de um, prioriza BTRFS
    for s in "${active_storages[@]}"; do
        local type=$(pvesm status | awk -v st="$s" '$1==st {print $2}')
        if [ "$type" == "btrfs" ]; then
            echo "$s"
            return
        fi
    done

    # Se não houver BTRFS, procura LVMThin ou DIR que aceite ISO
    for s in "${active_storages[@]}"; do
        local cfg=$(grep -E "^\s*$s\s+" /etc/pve/storage.cfg)
        local type=$(echo "$cfg" | awk '{print $2}')
        local content=$(echo "$cfg" | grep -oP 'content\s*=\s*\K.*')
        if [[ "$type" =~ ^(dir|lvmthin)$ ]] && [[ "$content" =~ iso ]]; then
            echo "$s"
            return
        fi
    done

    # Se nada encontrado, retorna o primeiro storage ativo
    echo "${active_storages[0]}"
}

# Usa a função
storages=($(get_iso_storage))


# --- Início do Script ---

clear
echo -e "${YELLOW}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║   Assistente de Criação de VM para Proxmox VE 3.0     ║${NC}"
echo -e "${YELLOW}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# Verificar se está rodando no Proxmox
if ! command -v qm &> /dev/null; then
    error_exit "Este script deve ser executado em um servidor Proxmox VE!"
fi

# Nome da VM
read -p "Digite o nome da sua VM: " vm_name
if [[ -z "$vm_name" ]]; then
    error_exit "Nome da VM não pode ser vazio."
fi

# ID da VM
vm_id=$(get_next_vmid)
echo -e "${GREEN}A VM será criada com o ID: ${vm_id}${NC}"
read -p "Deseja usar um ID diferente? (deixe vazio para usar $vm_id): " custom_id
if [[ ! -z "$custom_id" ]]; then
    validate_number "$custom_id"
    if qm status $custom_id &>/dev/null; then
        error_exit "VM com ID $custom_id já existe!"
    fi
    vm_id=$custom_id
fi

# Verificação de Storage
main_storage=$(find_main_storage)
if [[ -z "$main_storage" ]]; then
    error_exit "Nenhum storage adequado encontrado."
fi
echo -e "${GREEN}Storage principal detectado: ${main_storage}${NC}"

# ISO para instalação
echo ""
read -p "Deseja usar uma ISO para a instalação? (s/n) [s]: " use_iso
use_iso=${use_iso:-s}
iso_option=""

if [[ "$use_iso" == "s" || "$use_iso" == "S" ]]; then
    # Pega storage(s) ativos e válidos
    storages=($(get_active_storages))

    # Verifica se há apenas um storage disponível
    if [[ ${#storages[@]} -eq 1 ]]; then
        selected_storage="${storages[0]}"
        echo -e "${GREEN}Apenas um storage disponível. Selecionando automaticamente: ${selected_storage}${NC}"
        echo ""
    else
        # Listar storages ativos válidos para ISO
        echo -e "${CYAN}Storages disponíveis:${NC}"
        selected_storage=$(get_iso_storage)

        for i in "${!storages[@]}"; do
            prefix=" "
            [[ "${storages[$i]}" == "$selected_storage" ]] && prefix="*"  # Marca storage selecionado por padrão
            echo "  $((i+1))) ${storages[$i]} $prefix"
        done

        read -p "Selecione o storage [*=${selected_storage}]: " storage_choice
        if [[ "$storage_choice" =~ ^[0-9]+$ ]] && [[ $storage_choice -ge 1 && $storage_choice -le ${#storages[@]} ]]; then
            selected_storage="${storages[$((storage_choice-1))]}"
        fi
        
        echo -e "${GREEN}Storage selecionado: ${selected_storage}${NC}"
        echo ""
    fi
    
    # Listar ISOs numeradas
    if list_isos_numbered "$selected_storage"; then
        read -p "Selecione o número da ISO (ou 0 para pular): " iso_choice
        
        if [[ "$iso_choice" =~ ^[0-9]+$ ]] && [[ $iso_choice -ge 1 ]]; then
            iso_path=$(get_iso_path "$selected_storage" "$iso_choice")
            if [[ -n "$iso_path" ]]; then
                iso_option="--cdrom ${iso_path}"
                echo -e "${GREEN}ISO selecionada: ${iso_path}${NC}"
            else
                echo -e "${YELLOW}ISO inválida selecionada${NC}"
            fi
        fi
    fi
fi


# Tipo de SO
echo ""
echo -e "${CYAN}Selecione o tipo de sistema operacional:${NC}"
echo "1) Linux (kernel 6.x)"
echo "2) Windows 11/2022"
echo "3) Windows 10/2016-2019"
echo "4) Windows 7/8/2012"
echo "5) Outro Linux (kernel 2.6-5.x)"
read -p "Digite o número correspondente [1]: " os_type_choice
os_type_choice=${os_type_choice:-1}

case $os_type_choice in
    1) os_type="l26" ;;
    2) os_type="win11" ;;
    3) os_type="win10" ;;
    4) os_type="win8" ;;
    5) os_type="l24" ;;
    *) 
        echo -e "${YELLOW}Opção inválida. Usando Linux por padrão.${NC}"
        os_type="l26"
        ;;
esac

# VirtIO Drivers para Windows
virtio_option=""
if [[ "$os_type" == win* ]]; then
    read -p "Adicionar ISO de drivers VirtIO para Windows? (s/n) [s]: " add_virtio
    add_virtio=${add_virtio:-s}
    
    if [[ "$add_virtio" == "s" || "$add_virtio" == "S" ]]; then
        # Buscar ISO VirtIO automaticamente
        echo -e "${CYAN}Procurando ISO VirtIO...${NC}"
        
        # Procurar em todos os storages
        virtio_found=false
        for storage in $(pvesm status | awk '$2 ~ /(dir|nfs|cifs)/ {print $1}'); do
            virtio_iso=$(pvesm list "$storage" --content iso 2>/dev/null | grep -i "virtio-win" | head -1 | awk '{print $2}')
            if [[ ! -z "$virtio_iso" ]]; then
                virtio_path="${storage}:iso/$(basename "$virtio_iso")"
                echo -e "${GREEN}ISO VirtIO encontrada: ${virtio_path}${NC}"
                virtio_option="--ide2 ${virtio_path},media=cdrom"
                virtio_found=true
                break
            fi
        done
        
        # Se não encontrou, oferecer download
        if [[ "$virtio_found" == false ]]; then
            echo -e "${YELLOW}ISO VirtIO não encontrada nos storages.${NC}"
            read -p "Deseja baixar a ISO VirtIO oficial? (s/n) [s]: " download_virtio
            download_virtio=${download_virtio:-s}
            
            if [[ "$download_virtio" == "s" || "$download_virtio" == "S" ]]; then
                if download_virtio_iso "$main_storage"; then
                    virtio_option="--ide2 ${main_storage}:iso/virtio-win-0.1.271.iso,media=cdrom"
                fi
            fi
        fi
    fi
fi

# BIOS/UEFI
echo ""
echo -e "${CYAN}Selecione o tipo de BIOS:${NC}"
echo "1) SeaBIOS (Legacy/BIOS)"
echo "2) OVMF/UEFI"
echo "3) OVMF/UEFI com Secure Boot"
read -p "Digite o número correspondente [1]: " bios_choice
bios_choice=${bios_choice:-1}

bios_option="--bios seabios"
efi_disk_option=""

case $bios_choice in
    2|3)
        bios_option="--bios ovmf"
        # Perguntar sobre disco EFI
        read -p "Adicionar disco EFI? (s/n) [s]: " add_efi
        add_efi=${add_efi:-s}
        
        if [[ "$add_efi" == "s" || "$add_efi" == "S" ]]; then
            if [[ "$bios_choice" == "3" ]]; then
                efi_disk_option="--efidisk0 ${main_storage}:1,efitype=4m,pre-enrolled-keys=1"
                echo -e "${GREEN}Disco EFI será criado com Secure Boot habilitado${NC}"
            else
                efi_disk_option="--efidisk0 ${main_storage}:1,efitype=4m,pre-enrolled-keys=0"
                echo -e "${GREEN}Disco EFI será criado${NC}"
            fi
        else
            echo -e "${YELLOW}Aviso: UEFI sem disco EFI pode não funcionar corretamente${NC}"
        fi
        ;;
esac

# TPM (útil para Windows 11)
tpm_option=""
if [[ "$os_type" == "win11" ]]; then
    echo -e "${YELLOW}Windows 11 requer TPM 2.0 para instalação padrão.${NC}"
    read -p "Adicionar chip TPM 2.0 virtual? (s/n) [s]: " add_tpm
    add_tpm=${add_tpm:-s}
    if [[ "$add_tpm" == "s" || "$add_tpm" == "S" ]]; then
        tpm_option="--tpmstate0 ${main_storage}:1,version=v2.0"
    fi
else
    read -p "Adicionar chip TPM virtual? (s/n) [n]: " add_tpm
    if [[ "$add_tpm" == "s" || "$add_tpm" == "S" ]]; then
        echo "Versões disponíveis: 1) v1.2  2) v2.0"
        read -p "Escolha a versão [2]: " tpm_ver
        tpm_ver=${tpm_ver:-2}
        tpm_version="v2.0"
        [[ "$tpm_ver" == "1" ]] && tpm_version="v1.2"
        tpm_option="--tpmstate0 ${main_storage}:1,version=${tpm_version}"
    fi
fi

# CPU
echo ""
echo -e "${CYAN}Configuração de CPU:${NC}"
echo "Tipos de CPU disponíveis:"
echo "1) host (melhor performance - passa recursos da CPU física)"
echo "2) kvm64 (compatível com migração ao vivo)"
echo "3) x86-64-v2-AES (moderno, com AES)"
read -p "Escolha o tipo de CPU [1]: " cpu_type_choice
cpu_type_choice=${cpu_type_choice:-1}

case $cpu_type_choice in
    1) cpu_type="host" ;;
    2) cpu_type="kvm64" ;;
    3) cpu_type="x86-64-v2-AES" ;;
    *) cpu_type="host" ;;
esac

read -p "Número de sockets [1]: " sockets
sockets=${sockets:-1}
validate_number "$sockets"

read -p "Número de cores por socket [2]: " cores
cores=${cores:-2}
validate_number "$cores"

total_cores=$((sockets * cores))
echo -e "${GREEN}Total de vCPUs: ${total_cores}${NC}"

# Memória RAM
echo ""
echo -e "${CYAN}Configuração de Memória:${NC}"
read -p "Quantidade de RAM em MB (ex: 2048 para 2GB) [2048]: " memory
memory=${memory:-2048}
validate_number "$memory"

# Configurar ballooning (memória dinâmica)
read -p "Habilitar ballooning de memória? (s/n) [s]: " use_balloon
use_balloon=${use_balloon:-s}
balloon_option=""
if [[ "$use_balloon" == "n" || "$use_balloon" == "N" ]]; then
    balloon_option="--balloon 0"
else
    read -p "Memória mínima em MB [$(($memory/2))]: " min_memory
    min_memory=${min_memory:-$(($memory/2))}
    validate_number "$min_memory"
    balloon_option="--balloon $min_memory"
fi

# Disco Principal - Nova opção de não adicionar disco
echo ""
echo -e "${CYAN}Configuração de Armazenamento:${NC}"
read -p "Adicionar disco principal à VM? (s/n) [s]: " add_disk
add_disk=${add_disk:-s}

disk_option=""
boot_disk=""
scsi_hw=""

if [[ "$add_disk" == "s" || "$add_disk" == "S" ]]; then
    read -p "Tamanho do disco em GB [32]: " disk_size
    disk_size=${disk_size:-32}
    validate_number "$disk_size"
    
    echo "Tipo de barramento do disco:"
    echo "1) VirtIO (melhor performance)"
    echo "2) SCSI (boa compatibilidade)"
    echo "3) SATA (compatibilidade máxima)"
    echo "4) IDE (legado)"
    read -p "Escolha o tipo [1]: " disk_bus
    disk_bus=${disk_bus:-1}
    
    case $disk_bus in
        1) 
            disk_option="--virtio0 ${main_storage}:${disk_size}"
            boot_disk="virtio0"
            ;;
        2) 
            disk_option="--scsi0 ${main_storage}:${disk_size}"
            boot_disk="scsi0"
            scsi_hw="--scsihw virtio-scsi-pci"
            ;;
        3) 
            disk_option="--sata0 ${main_storage}:${disk_size}"
            boot_disk="sata0"
            ;;
        4) 
            disk_option="--ide0 ${main_storage}:${disk_size}"
            boot_disk="ide0"
            ;;
        *)
            disk_option="--virtio0 ${main_storage}:${disk_size}"
            boot_disk="virtio0"
            ;;
    esac
    
    # Cache do disco
    echo "Modo de cache do disco:"
    echo "1) none (padrão, seguro)"
    echo "2) writethrough (seguro, lento)"
    echo "3) writeback (rápido, menos seguro)"
    echo "4) unsafe (muito rápido, não recomendado para produção)"
    read -p "Escolha o modo de cache [1]: " cache_mode
    cache_mode=${cache_mode:-1}
    
    case $cache_mode in
        2) disk_option="${disk_option},cache=writethrough" ;;
        3) disk_option="${disk_option},cache=writeback" ;;
        4) disk_option="${disk_option},cache=unsafe" ;;
        *) disk_option="${disk_option},cache=none" ;;
    esac
    
    # Discard/TRIM para SSDs
    read -p "Habilitar TRIM/Discard (para SSDs)? (s/n) [n]: " enable_discard
    if [[ "$enable_discard" == "s" || "$enable_discard" == "S" ]]; then
        disk_option="${disk_option},discard=on"
    fi
else
    echo -e "${YELLOW}VM será criada sem disco principal (diskless)${NC}"
    echo -e "${CYAN}Você poderá adicionar discos posteriormente ou usar boot via rede${NC}"
fi

# Rede - Com lista numerada de bridges
echo ""
echo -e "${CYAN}Configuração de Rede:${NC}"

# Listar bridges numeradas e capturar saída completa
bridge_output=$(list_bridges_numbered)

# Mostrar apenas a parte visual (sem o marcador BRIDGES:)
echo "$bridge_output" | grep -v "^BRIDGES:"

# Obter seleção do usuário
read -p "Selecione o número da bridge [1]: " bridge_choice
bridge_choice=${bridge_choice:-1}

# Obter a bridge selecionada
bridge=$(get_selected_bridge "$bridge_output" "$bridge_choice")

echo -e "${GREEN}Bridge selecionada: ${bridge}${NC}"

echo ""
echo "Modelo de placa de rede:"
echo "1) VirtIO (melhor performance)"
echo "2) Intel E1000 (boa compatibilidade)"
echo "3) RTL8139 (compatibilidade com sistemas antigos)"
echo "4) VMware vmxnet3"
read -p "Escolha o modelo [1]: " net_model
net_model=${net_model:-1}

case $net_model in
    1) net_model="virtio" ;;
    2) net_model="e1000" ;;
    3) net_model="rtl8139" ;;
    4) net_model="vmxnet3" ;;
    *) net_model="virtio" ;;
esac

# Gerar MAC address ou usar padrão
read -p "Gerar endereço MAC aleatório? (s/n) [s]: " gen_mac
gen_mac=${gen_mac:-s}
if [[ "$gen_mac" == "n" || "$gen_mac" == "N" ]]; then
    net_option="--net0 ${net_model},bridge=${bridge}"
else
    # Gerar MAC aleatório no formato Proxmox
    mac="BC:24:11:$(printf '%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"
    net_option="--net0 ${net_model}=${mac},bridge=${bridge}"
fi

# Firewall
read -p "Habilitar firewall para esta VM? (s/n) [s]: " enable_fw
enable_fw=${enable_fw:-s}
if [[ "$enable_fw" == "n" || "$enable_fw" == "N" ]]; then
    net_option="${net_option},firewall=0"
fi

# VLAN (opcional)
read -p "Configurar VLAN? (deixe vazio para não usar): " vlan_tag
if [[ ! -z "$vlan_tag" ]]; then
    validate_number "$vlan_tag"
    net_option="${net_option},tag=${vlan_tag}"
fi

# Display/Gráficos
echo ""
echo -e "${CYAN}Configuração de Display:${NC}"
echo "1) VGA padrão"
echo "2) SPICE (melhor para desktop remoto)"
echo "3) VirtIO-GPU (requer drivers)"
echo "4) QXL (bom para SPICE)"
echo "5) Serial console apenas"
echo "6) None (sem display)"
read -p "Escolha o tipo de display [1]: " display_type
display_type=${display_type:-1}

case $display_type in
    1) display_option="--vga std" ;;
    2) display_option="--vga qxl --agent 1" ;;
    3) display_option="--vga virtio" ;;
    4) display_option="--vga qxl" ;;
    5) display_option="--vga serial0 --serial0 socket" ;;
    6) display_option="--vga none" ;;
    *) display_option="--vga std" ;;
esac

# QEMU Guest Agent
if [[ "$display_type" != "2" ]]; then
    read -p "Instalar QEMU Guest Agent? (s/n) [s]: " install_agent
    install_agent=${install_agent:-s}
    if [[ "$install_agent" == "s" || "$install_agent" == "S" ]]; then
        agent_option="--agent 1"
    else
        agent_option="--agent 0"
    fi
else
    agent_option=""
fi

# Boot options
echo ""
echo -e "${CYAN}Opções de Boot:${NC}"

# Configurar ordem de boot apenas se houver disco
boot_order_option=""
if [[ ! -z "$boot_disk" ]]; then
    boot_order_option="--boot order=${boot_disk}"
elif [[ ! -z "$iso_option" ]]; then
    # Se não há disco mas há ISO, boot pela ISO
    boot_order_option="--boot order=d"
else
    # Sem disco e sem ISO, configurar para PXE
    echo -e "${YELLOW}Configurando boot via rede (PXE)${NC}"
    boot_order_option="--boot order=n"
fi

read -p "Iniciar VM ao ligar o host? (s/n) [n]: " onboot
onboot_option=""
if [[ "$onboot" == "s" || "$onboot" == "S" ]]; then
    onboot_option="--onboot 1"
    read -p "Delay de boot em segundos [0]: " boot_delay
    boot_delay=${boot_delay:-0}
    if [[ "$boot_delay" != "0" ]]; then
        onboot_option="${onboot_option} --startup order=1,up=${boot_delay}"
    fi
fi

# Proteção contra exclusão acidental
read -p "Proteger VM contra exclusão acidental? (s/n) [n]: " protect
protect_option=""
if [[ "$protect" == "s" || "$protect" == "S" ]]; then
    protect_option="--protection 1"
fi

# Recursos avançados
echo ""
echo -e "${CYAN}Recursos Avançados:${NC}"

# Nested virtualization (apenas se CPU = host)
numa_option=""
if [[ "$cpu_type" == "host" ]]; then
    read -p "Habilitar virtualização aninhada? (s/n) [n]: " nested
    if [[ "$nested" == "s" || "$nested" == "S" ]]; then
        cpu_option="--cpu ${cpu_type},flags=+vmx"
    else
        cpu_option="--cpu ${cpu_type}"
    fi
else
    cpu_option="--cpu ${cpu_type}"
fi

# NUMA
if [[ $sockets -gt 1 ]]; then
    read -p "Habilitar NUMA? (s/n) [n]: " enable_numa
    if [[ "$enable_numa" == "s" || "$enable_numa" == "S" ]]; then
        numa_option="--numa 1"
    fi
fi

# Tablet pointer (útil para GUI)
read -p "Habilitar tablet USB (melhora cursor no VNC/SPICE)? (s/n) [s]: " tablet
tablet=${tablet:-s}
tablet_option=""
if [[ "$tablet" == "n" || "$tablet" == "N" ]]; then
    tablet_option="--tablet 0"
fi

# Descrição da VM
echo ""
read -p "Adicionar descrição à VM? (s/n) [n]: " add_desc
desc_option=""
if [[ "$add_desc" == "s" || "$add_desc" == "S" ]]; then
    echo "Digite a descrição (termine com linha vazia):"
    description=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && break
        description="${description}${line}\n"
    done
    if [[ ! -z "$description" ]]; then
        desc_option="--description \"${description}\""
    fi
fi

# Tags (útil para organização)
read -p "Adicionar tags à VM? (separadas por vírgula): " tags
tags_option=""
if [[ ! -z "$tags" ]]; then
    tags_option="--tags \"${tags}\""
fi

# --- Construir e executar comando ---

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Resumo da Configuração:${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo "Nome: $vm_name (ID: $vm_id)"
echo "SO: $os_type"
echo "CPU: $cpu_type ($total_cores vCPUs)"
echo "RAM: ${memory}MB"
if [[ ! -z "$disk_option" ]]; then
    echo "Disco: ${disk_size}GB"
else
    echo "Disco: Nenhum (VM diskless)"
fi
echo "Bridge: $bridge"
echo "Storage: $main_storage"
if [[ ! -z "$efi_disk_option" ]]; then
    echo "EFI: Sim"
fi
if [[ ! -z "$tpm_option" ]]; then
    echo "TPM: Sim"
fi
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"

# Construir comando completo
cmd="qm create $vm_id"
cmd="$cmd --name \"$vm_name\""
cmd="$cmd --ostype $os_type"
cmd="$cmd --sockets $sockets --cores $cores"
cmd="$cmd --memory $memory"
cmd="$cmd $cpu_option"
cmd="$cmd $net_option"
cmd="$cmd $display_option"

# Adicionar disco apenas se foi configurado
[[ ! -z "$disk_option" ]] && cmd="$cmd $disk_option"

# Adicionar ordem de boot
[[ ! -z "$boot_order_option" ]] && cmd="$cmd $boot_order_option"

# Adicionar opções condicionais
[[ ! -z "$iso_option" ]] && cmd="$cmd $iso_option"
[[ ! -z "$virtio_option" ]] && cmd="$cmd $virtio_option"
[[ ! -z "$bios_option" ]] && cmd="$cmd $bios_option"
[[ ! -z "$efi_disk_option" ]] && cmd="$cmd $efi_disk_option"
[[ ! -z "$tpm_option" ]] && cmd="$cmd $tpm_option"
[[ ! -z "$balloon_option" ]] && cmd="$cmd $balloon_option"
[[ ! -z "$agent_option" ]] && cmd="$cmd $agent_option"
[[ ! -z "$onboot_option" ]] && cmd="$cmd $onboot_option"
[[ ! -z "$protect_option" ]] && cmd="$cmd $protect_option"
[[ ! -z "$numa_option" ]] && cmd="$cmd $numa_option"
[[ ! -z "$tablet_option" ]] && cmd="$cmd $tablet_option"
[[ ! -z "$scsi_hw" ]] && cmd="$cmd $scsi_hw"
[[ ! -z "$desc_option" ]] && cmd="$cmd $desc_option"
[[ ! -z "$tags_option" ]] && cmd="$cmd $tags_option"

echo ""
echo -e "${CYAN}Comando a ser executado:${NC}"
echo -e "${GREEN}$cmd${NC}"
echo ""

read -p "Confirmar criação da VM? (s/n): " confirm
if [[ "$confirm" != "s" && "$confirm" != "S" ]]; then
    echo -e "${YELLOW}Operação cancelada.${NC}"
    exit 0
fi

# Executar comando
echo -e "${CYAN}Criando VM...${NC}"
eval $cmd

if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         VM criada com sucesso!                        ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Próximos passos:${NC}"
    echo "1. Para iniciar a VM: qm start $vm_id"
    echo "2. Para acessar o console: qm console $vm_id"
    echo "3. Para ver o status: qm status $vm_id"
    echo "4. Interface web: https://$(hostname -I | awk '{print $1}'):8006"
    
    # Avisos especiais
    if [[ -z "$disk_option" ]]; then
        echo ""
        echo -e "${YELLOW}⚠ Atenção: VM criada sem disco!${NC}"
        echo -e "${CYAN}Você pode:${NC}"
        echo "  - Adicionar um disco: qm set $vm_id --scsi0 ${main_storage}:32"
        echo "  - Configurar boot via rede (PXE)"
        echo "  - Anexar um disco existente"
    fi
    
    if [[ "$os_type" == "win11" ]] && [[ -z "$tpm_option" ]]; then
        echo ""
        echo -e "${YELLOW}⚠ Windows 11 sem TPM pode ter problemas na instalação${NC}"
    fi
    
    if [[ "$bios_option" == "--bios ovmf" ]] && [[ -z "$efi_disk_option" ]]; then
        echo ""
        echo -e "${YELLOW}⚠ UEFI sem disco EFI pode não funcionar corretamente${NC}"
    fi
    
    echo ""
    read -p "Deseja iniciar a VM agora? (s/n): " start_now
    if [[ "$start_now" == "s" || "$start_now" == "S" ]]; then
        qm start $vm_id
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}VM iniciada com sucesso!${NC}"
            
            # Mostrar informações de conexão
            echo ""
            echo -e "${CYAN}Informações de Conexão:${NC}"
            echo "Console Web: https://$(hostname -I | awk '{print $1}'):8006/?console=kvm&vmid=${vm_id}&vmname=${vm_name}"
            
            if [[ "$display_option" == *"spice"* ]] || [[ "$display_option" == *"qxl"* ]]; then
                echo "SPICE: Use virt-viewer ou Remote Viewer para conectar"
                echo "Comando: remote-viewer spice://$(hostname -I | awk '{print $1}'):3128"
            fi
            
            # Se for Windows e tiver VirtIO, lembrar sobre os drivers
            if [[ "$os_type" == win* ]] && [[ ! -z "$virtio_option" ]]; then
                echo ""
                echo -e "${YELLOW}Lembrete: Durante a instalação do Windows:${NC}"
                echo "1. Quando não encontrar discos, clique em 'Carregar driver'"
                echo "2. Navegue até a unidade de CD com os drivers VirtIO"
                echo "3. Selecione a pasta correspondente à sua versão do Windows"
                echo "4. Instale os drivers de armazenamento (viostor) e rede (NetKVM)"
            fi
        else
            echo -e "${RED}Erro ao iniciar a VM${NC}"
        fi
    fi
else
    echo -e "${RED}Erro ao criar a VM. Verifique os logs para mais detalhes.${NC}"
    echo "Para ver os logs: journalctl -xe"
    exit 1
fi

# Oferecer criação de snapshot inicial
echo ""
read -p "Criar snapshot inicial da VM? (s/n) [n]: " create_snapshot
if [[ "$create_snapshot" == "s" || "$create_snapshot" == "S" ]]; then
    read -p "Nome do snapshot [initial]: " snapshot_name
    snapshot_name=${snapshot_name:-initial}
    
    echo -e "${CYAN}Criando snapshot...${NC}"
    qm snapshot $vm_id "$snapshot_name" --description "Snapshot inicial após criação"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Snapshot '$snapshot_name' criado com sucesso!${NC}"
    else
        echo -e "${YELLOW}Aviso: Não foi possível criar o snapshot${NC}"
    fi
fi

# Salvar configuração em arquivo
echo ""
read -p "Salvar configuração em arquivo? (s/n) [n]: " save_config
if [[ "$save_config" == "s" || "$save_config" == "S" ]]; then
    config_file="/root/vm_configs/vm_${vm_id}_${vm_name}_$(date +%Y%m%d_%H%M%S).conf"
    mkdir -p /root/vm_configs
    
    cat > "$config_file" << EOF
# Configuração da VM ${vm_name} (ID: ${vm_id})
# Criada em: $(date)
# ============================================

VM_NAME="${vm_name}"
VM_ID="${vm_id}"
OS_TYPE="${os_type}"
CPU_TYPE="${cpu_type}"
SOCKETS="${sockets}"
CORES="${cores}"
MEMORY="${memory}MB"
DISK_SIZE="${disk_size}GB"
BRIDGE="${bridge}"
STORAGE="${main_storage}"
BIOS="${bios_option}"
EFI="${efi_disk_option}"
TPM="${tpm_option}"

# Comando utilizado para criar a VM:
${cmd}

# Para recriar uma VM similar:
# 1. Ajuste o ID da VM (VM_ID)
# 2. Execute o comando acima

# Notas adicionais:
$(if [[ -z "$disk_option" ]]; then echo "- VM criada sem disco (diskless)"; fi)
$(if [[ ! -z "$virtio_option" ]]; then echo "- Drivers VirtIO incluídos"; fi)
$(if [[ ! -z "$efi_disk_option" ]]; then echo "- Disco EFI configurado"; fi)
$(if [[ ! -z "$tpm_option" ]]; then echo "- TPM virtual configurado"; fi)
EOF
    
    echo -e "${GREEN}Configuração salva em: ${config_file}${NC}"
fi

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}         Processo concluído com sucesso!                ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}Comandos úteis para gerenciar a VM ${vm_id}:${NC}"
echo "  qm start $vm_id      - Iniciar VM"
echo "  qm stop $vm_id       - Parar VM"
echo "  qm reset $vm_id      - Reiniciar VM"
echo "  qm suspend $vm_id    - Suspender VM"
echo "  qm resume $vm_id     - Retomar VM"
echo "  qm migrate $vm_id    - Migrar VM"
echo "  qm clone $vm_id      - Clonar VM"
echo "  qm destroy $vm_id    - Destruir VM"

if [[ -z "$disk_option" ]]; then
    echo ""
    echo -e "${CYAN}Comandos para adicionar disco:${NC}"
    echo "  qm set $vm_id --scsi0 ${main_storage}:32           - Adicionar disco SCSI de 32GB"
    echo "  qm set $vm_id --virtio0 ${main_storage}:50         - Adicionar disco VirtIO de 50GB"
    echo "  qm set $vm_id --ide2 /dev/sdb                      - Adicionar disco físico"
    echo "  qm importdisk $vm_id arquivo.qcow2 ${main_storage} - Importar disco existente"
fi

echo ""
echo -e "${CYAN}Log do script salvo em: /var/log/proxmox-vm-creator.log${NC}"

# Salvar log
{
    echo "=========================================="
    echo "VM Criada: $(date)"
    echo "ID: $vm_id"
    echo "Nome: $vm_name"
    echo "Comando: $cmd"
    echo "=========================================="
} >> /var/log/proxmox-vm-creator.log

echo ""
echo -e "${GREEN}Obrigado por usar o Assistente de Criação de VM!${NC}"
echo -e "${CYAN}Versão 3.0 - Script desenvolvido para Proxmox VE${NC}"
