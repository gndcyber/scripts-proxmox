#!/bin/bash

# Este script cria um novo usuário com permissões de sudo em todos os CTs Linux.
# Requer execução como root no host Proxmox.

# --- Configurações e Cores ---
VERDE="\e[32m"
VERMELHO="\e[31m"
AMARELO="\e[33m"
NORMAL="\e[0m"

# --- Validação de Entrada ---
read -p "Digite o nome do novo usuário: " USERNAME
if [[ -z "$USERNAME" ]]; then
    echo -e "${VERMELHO}Nome de usuário não pode ser vazio. Saindo.${NORMAL}"
    exit 1
fi

# Usa `read -r` para evitar que barras invertidas sejam interpretadas
read -r -s -p "Digite a senha para o usuário $USERNAME: " PASSWORD
echo
if [[ -z "$PASSWORD" ]]; then
    echo -e "${VERMELHO}A senha não pode ser vazia. Saindo.${NORMAL}"
    exit 1
fi

read -r -s -p "Confirme a senha: " PASSWORD2
echo
if [[ "$PASSWORD" != "$PASSWORD2" ]]; then
    echo -e "${VERMELHO}As senhas não coincidem. Saindo.${NORMAL}"
    exit 1
fi

# --- Preparação e Lista de CTs ---
CT_LIST=$(pct list | awk 'NR > 1 {print $1}')

if [[ -z "$CT_LIST" ]]; then
    echo -e "${AMARELO}Nenhum CT encontrado. O script será encerrado.${NORMAL}"
    exit 0
fi

echo -e "\n${AMARELO}Iniciando a criação do usuário '$USERNAME' em todos os CTs...${NORMAL}"

# --- Loop para Processar CTs ---
for CTID in $CT_LIST; do
    echo -e "\n------------------------------------------------"
    echo -e "Processando CT ID: ${AMARELO}$CTID${NORMAL}"

    CT_STATUS=$(pct status "$CTID")
    if [[ "$CT_STATUS" != "status: running" ]]; then
        echo -e "${AMARELO}CT $CTID não está rodando. Ignorando.${NORMAL}"
        continue
    fi
    
    # Verifica se o usuário já existe
    if pct exec "$CTID" -- id "$USERNAME" &>/dev/null; then
        echo -e "${AMARELO}Usuário '$USERNAME' já existe no CT $CTID. Ignorando.${NORMAL}"
        continue
    fi

    echo -e "${AMARELO}Criando o usuário '$USERNAME'...${NORMAL}"
    # O comando `useradd` pode falhar em algumas distros se o diretório já existe.
    # O `||` (ou) é usado para garantir que o script não pare em caso de erro menor.
    pct exec "$CTID" -- bash -c "useradd -m -s /bin/bash '$USERNAME' 2>/dev/null || true"
    if [ $? -ne 0 ]; then
        echo -e "${VERMELHO}Erro ao criar o usuário '$USERNAME' em CT $CTID. Verifique o log.${NORMAL}"
        continue
    fi

    # Define a senha de forma mais segura com `printf`
    echo -e "${AMARELO}Configurando a senha...${NORMAL}"
    printf "%s:%s" "$USERNAME" "$PASSWORD" | pct exec "$CTID" -- chpasswd
    if [ $? -ne 0 ]; then
        echo -e "${VERMELHO}Erro ao definir a senha para o usuário '$USERNAME' em CT $CTID.${NORMAL}"
        continue
    fi

    # Adiciona o usuário aos grupos de sudo
    echo -e "${AMARELO}Concedendo permissões sudo...${NORMAL}"
    pct exec "$CTID" -- bash -c "usermod -aG sudo '$USERNAME' || usermod -aG wheel '$USERNAME' || true"
    if [ $? -ne 0 ]; then
        echo -e "${VERMELHO}Não foi possível adicionar o usuário ao grupo 'sudo' ou 'wheel' em CT $CTID.${NORMAL}"
    else
        echo -e "${VERDE}Usuário '$USERNAME' criado com sucesso em CT $CTID!${NORMAL}"
    fi
done

echo -e "------------------------------------------------"
echo -e "${VERDE}Processo concluído.${NORMAL}"
