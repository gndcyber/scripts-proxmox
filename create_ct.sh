#!/bin/bash

# --- Proxpert CT Creation Script (Versão Universal) ---
# Autor: Adaptado e aprimorado por Gemini + Revisado

# --- CORES ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_BLUE='\033[0;34m'
C_YELLOW='\033[1;33m'

# --- FUNÇÃO DE ERRO ---
function die() {
    echo -e "${C_RED}ERRO: $1${C_RESET}" >&2
    exit 1
}

# --- FUNÇÃO DE LISTA ---
function select_from_list() {
    local prompt_msg="$1"
    shift
    local options=("$@")

    echo -e "${C_BLUE}$prompt_msg${C_RESET}"
    for i in "${!options[@]}"; do
        echo "  [$(($i + 1))] ${options[$i]}"
    done

    local choice
    while true; do
        read -p "Selecione o número correspondente: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "${#options[@]}" ]; then
            REPLY="${options[$(($choice - 1))]}"
            return 0
        else
            echo -e "${C_RED}Seleção inválida. Tente novamente.${C_RESET}"
        fi
    done
}

clear
echo -e "${C_GREEN}--- Assistente Proxpert para Criação de Container (CT) ---${C_RESET}"
echo

# --- 1. HOSTNAME E SENHA ---
while [[ -z "$CT_HOSTNAME" ]]; do
    read -p "Digite o hostname para o novo container: " CT_HOSTNAME
done

while true; do
    read -sp "Digite a senha para o usuário 'root': " CT_PASSWORD
    echo
    read -sp "Confirme a senha: " CT_PASSWORD_CONFIRM
    echo

    if [[ "$CT_PASSWORD" == "$CT_PASSWORD_CONFIRM" ]] && [[ -n "$CT_PASSWORD" ]] && [[ "${#CT_PASSWORD}" -ge 6 ]]; then
        break
    else
        if [[ -z "$CT_PASSWORD" ]]; then
            echo -e "${C_RED}A senha não pode ser vazia.${C_RESET}"
        elif [[ "${#CT_PASSWORD}" -lt 6 ]]; then
            echo -e "${C_RED}A senha deve ter no mínimo 6 caracteres.${C_RESET}"
        else
            echo -e "${C_RED}As senhas não coincidem.${C_RESET}"
        fi
    fi
done

# --- 2. CONTAINER PRIVILEGIADO ---
read -p "O container será privilegiado? (s/N): " choice
PRIVILEGED_FLAG="--unprivileged 1"
if [[ "$choice" =~ ^[Ss]$ ]]; then
    PRIVILEGED_FLAG=""
    echo -e "${C_YELLOW}Aviso: Containers privilegiados possuem menos isolamento de segurança.${C_RESET}"
fi

# --- 3. TEMPLATE ---
echo -e "\n${C_BLUE}Buscando templates disponíveis...${C_RESET}"
TEMPLATE_STORAGES=$(pvesm status -content vztmpl | tail -n +2 | awk '{print $1}')
[[ -z "$TEMPLATE_STORAGES" ]] && die "Nenhum storage habilitado para 'CT Templates'."

ALL_TEMPLATES=()
for storage in $TEMPLATE_STORAGES; do
    readarray -t templates_on_storage < <(pveam list "$storage" | awk 'NR>1 {print $1}')
    ALL_TEMPLATES+=("${templates_on_storage[@]}")
done

[[ ${#ALL_TEMPLATES[@]} -eq 0 ]] && die "Nenhum template de container foi encontrado."

if [ ${#ALL_TEMPLATES[@]} -eq 1 ]; then
    CT_TEMPLATE=${ALL_TEMPLATES[0]}
    echo -e "${C_BLUE}Selecionado automaticamente: ${C_YELLOW}$CT_TEMPLATE${C_RESET}"
else
    select_from_list "Selecione o template a ser utilizado:" "${ALL_TEMPLATES[@]}"
    CT_TEMPLATE=$REPLY
fi

# --- 4. RECURSOS ---
echo -e "\n${C_BLUE}Buscando storages para discos...${C_RESET}"
DISK_STORAGES=$(pvesm status -content rootdir,images | awk 'NR > 1 {print $1}')
[[ -z "$DISK_STORAGES" ]] && die "Nenhum storage habilitado para discos encontrado."

mapfile -t DISK_STORAGES_ARRAY <<< "$DISK_STORAGES"
if [ ${#DISK_STORAGES_ARRAY[@]} -eq 1 ]; then
    CT_STORAGE=${DISK_STORAGES_ARRAY[0]}
    echo -e "${C_BLUE}Storage selecionado: ${C_YELLOW}$CT_STORAGE${C_RESET}"
else
    select_from_list "Selecione o storage para o disco raiz:" "${DISK_STORAGES_ARRAY[@]}"
    CT_STORAGE=$REPLY
fi

read -p "Tamanho do disco raiz em GB (padrão: 8): " CT_ROOTFS_SIZE
read -p "Cores de CPU (padrão: 1): " CT_CORES
read -p "Memória RAM em MiB (padrão: 512): " CT_MEMORY
read -p "SWAP em MiB (padrão: 256): " CT_SWAP

CT_ROOTFS_SIZE=${CT_ROOTFS_SIZE:-8}
CT_CORES=${CT_CORES:-1}
CT_MEMORY=${CT_MEMORY:-512}
CT_SWAP=${CT_SWAP:-256}

ADD_EXTRA_DISK=false
read -p "Deseja adicionar um disco extra? (s/N): " choice
if [[ "$choice" =~ ^[Ss]$ ]]; then
    read -p "Tamanho do disco extra em GB: " CT_EXTRA_DISK_SIZE
    read -p "Ponto de montagem (ex: /mnt/data): " CT_EXTRA_DISK_MP
    [[ -z "$CT_EXTRA_DISK_MP" ]] && die "O ponto de montagem não pode ser vazio."
    ADD_EXTRA_DISK=true
fi

# --- 5. REDE ---
echo -e "\n${C_BLUE}Buscando bridges...${C_RESET}"
BRIDGES=$(ip -br a | awk '/^vmbr/ {print $1}')
[[ -z "$BRIDGES" ]] && die "Nenhuma bridge (vmbr) encontrada."
mapfile -t BRIDGES_ARRAY <<< "$BRIDGES"

if [ ${#BRIDGES_ARRAY[@]} -eq 1 ]; then
    CT_BRIDGE=${BRIDGES_ARRAY[0]}
else
    select_from_list "Selecione a bridge de rede:" "${BRIDGES_ARRAY[@]}"
    CT_BRIDGE=$REPLY
fi

read -p "Nome da interface de rede no CT [eth0]: " CT_NET_NAME
CT_NET_NAME=${CT_NET_NAME:-eth0}

IP_MODE=0
read -p "Configuração de IP [0=DHCP, 1=Static] (padrão: 0): " IP_MODE
IP_MODE=${IP_MODE:-0}
NET_OPTS="name=${CT_NET_NAME},bridge=${CT_BRIDGE}"

if [ "$IP_MODE" -eq 1 ]; then
    read -p "Endereço IPv4/CIDR (ex: 192.168.1.101/24): " CT_IPV4
    read -p "Gateway IPv4 (ex: 192.168.1.1): " CT_GW4
    NET_OPTS+=",ip=${CT_IPV4},gw=${CT_GW4}"

    read -p "Endereço IPv6/CIDR (opcional): " CT_IPV6
    if [[ -n "$CT_IPV6" ]]; then
        read -p "Gateway IPv6: " CT_GW6
        NET_OPTS+=",ip6=${CT_IPV6},gw6=${CT_GW6}"
    fi
else
    NET_OPTS+=",ip=dhcp"
fi

# DNS
read -p "Usar domínio padrão (gndcyber.com.br)? (S/n): " choice
CT_DNS_DOMAIN="gndcyber.com.br"
[[ "$choice" =~ ^[Nn]$ ]] && read -p "Digite o domínio: " CT_DNS_DOMAIN

read -p "Usar DNS padrão (172.20.1.25)? (S/n): " choice
CT_DNS_SERVERS="172.20.1.25"
[[ "$choice" =~ ^[Nn]$ ]] && read -p "Digite o(s) servidor(es) DNS: " CT_DNS_SERVERS

# --- 6. RESUMO ---
NEXT_ID=$(pvesh get /cluster/nextid)

echo -e "\n${C_GREEN}--- Resumo CT ${NEXT_ID} ---${C_RESET}"
echo -e "Hostname:     ${C_YELLOW}${CT_HOSTNAME}${C_RESET}"
echo -e "Template:     ${C_YELLOW}${CT_TEMPLATE}${C_RESET}"
echo -e "Privilegiado: ${C_YELLOW}$( [[ -z "$PRIVILEGED_FLAG" ]] && echo "Sim" || echo "Não" )${C_RESET}"
echo -e "Storage:      ${C_YELLOW}${CT_STORAGE}${C_RESET}"
echo -e "RootFS:       ${C_YELLOW}${CT_ROOTFS_SIZE} GB${C_RESET}"
[[ "$ADD_EXTRA_DISK" = true ]] && echo -e "Extra Disk:   ${C_YELLOW}${CT_EXTRA_DISK_SIZE} GB em ${CT_EXTRA_DISK_MP}${C_RESET}"
echo -e "CPU:          ${C_YELLOW}${CT_CORES}${C_RESET}"
echo -e "RAM:          ${C_YELLOW}${CT_MEMORY} MiB${C_RESET}"
echo -e "SWAP:         ${C_YELLOW}${CT_SWAP} MiB${C_RESET}"
echo -e "Rede:         ${C_YELLOW}${NET_OPTS}${C_RESET}"
echo -e "DNS Domain:   ${C_YELLOW}${CT_DNS_DOMAIN}${C_RESET}"
echo -e "DNS Servers:  ${C_YELLOW}${CT_DNS_SERVERS}${C_RESET}"
echo

read -p "Confirmar criação? (S/n): " confirm
[[ ! "$confirm" =~ ^[Ss]$ ]] && { echo "Cancelado."; exit 0; }

# --- 7. CRIAÇÃO ---
echo -e "\n${C_BLUE}Criando container...${C_RESET}"

CMD_ARGS=(
    "$NEXT_ID" "$CT_TEMPLATE"
    --hostname "$CT_HOSTNAME"
    --cores "$CT_CORES"
    --memory "$CT_MEMORY"
    --swap "$CT_SWAP"
    --rootfs "${CT_STORAGE}:${CT_ROOTFS_SIZE}"
    --net0 "$NET_OPTS"
    --searchdomain "$CT_DNS_DOMAIN"
    --nameserver "$CT_DNS_SERVERS"
)

[[ -n "$PRIVILEGED_FLAG" ]] && CMD_ARGS+=($PRIVILEGED_FLAG)
[[ "$ADD_EXTRA_DISK" = true ]] && CMD_ARGS+=(--mp0 "${CT_STORAGE}:${CT_EXTRA_DISK_SIZE},mp=${CT_EXTRA_DISK_MP}")

if ! pct create "${CMD_ARGS[@]}" 2> >(tee /dev/fd/2); then
    die "Falha na criação do container."
fi

# aplicar senha de forma segura
echo "root:${CT_PASSWORD}" | pct exec "$NEXT_ID" chpasswd

echo -e "\n${C_GREEN}SUCESSO! Container ${NEXT_ID} (${CT_HOSTNAME}) criado.${C_RESET}"

read -p "Deseja iniciar o container agora? (S/n): " start_choice
[[ ! "$start_choice" =~ ^[Nn]$ ]] && { pct start "$NEXT_ID"; echo -e "${C_GREEN}Use: pct enter $NEXT_ID${C_RESET}"; }

exit 0

