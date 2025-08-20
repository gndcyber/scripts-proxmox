#!/bin/bash
# ============================================
# Script de Migração de Containers LXC no Proxmox
# Autor: Assistente de Automação
# Versão: 4.0
# ============================================

set -euo pipefail

# === Funções auxiliares ===
erro() {
    echo "ERRO: $1"
    exit 1
}

info() {
    echo -e "\033[1;32m=== $1 ===\033[0m"
}

# === Seleção do CT ===
info "Containers disponíveis no nó de origem"
pct list || erro "Falha ao listar CTs no nó de origem."

read -p "Digite o ID do CT a migrar: " CTID
[[ -z "$CTID" ]] && erro "ID do CT não pode ser vazio."

read -p "Digite o nó de destino (ex: srvmain): " DEST_NODE
[[ -z "$DEST_NODE" ]] && erro "Nó de destino não pode ser vazio."

# === Criação do backup ===
TIMESTAMP=$(date +%s)
BACKUP_DIR="/tmp/migracao_ct_${TIMESTAMP}"

info "Criando backup do CT ${CTID} em ${BACKUP_DIR}..."
mkdir -p "$BACKUP_DIR"

vzdump "$CTID" --dumpdir "$BACKUP_DIR" --compress zstd --mode stop || erro "Falha ao criar backup."

BACKUP_FILE=$(ls -t "$BACKUP_DIR"/vzdump-lxc-${CTID}-*.tar.zst 2>/dev/null | head -n1)
[[ ! -f "$BACKUP_FILE" ]] && erro "Backup não encontrado após execução do vzdump."

info "Backup criado com sucesso: $BACKUP_FILE"

# === Transferência do backup ===
info "Enviando backup para o nó de destino..."
scp "$BACKUP_FILE" root@"$DEST_NODE":/tmp/ || erro "Falha ao transferir o backup."

# === Seleção do próximo ID disponível no destino ===
NEWCTID=$(ssh root@"$DEST_NODE" "pvesh get /cluster/nextid") || erro "Não foi possível obter o próximo ID livre no destino."

info "CT será restaurado no destino com ID ${NEWCTID}"

# === Seleção do storage válido ===
info "Storages disponíveis no destino que suportam containers (rootdir):"

# Busca apenas os nomes e armazena em array
mapfile -t STORAGE_LIST < <(ssh root@"$DEST_NODE" "pvesm status --content rootdir | awk 'NR>1 {print \$1}'")

# Verifica se encontrou algum
[[ ${#STORAGE_LIST[@]} -eq 0 ]] && erro "Nenhum storage disponível no destino suporta containers (rootdir)."

# Lista numerada
for i in "${!STORAGE_LIST[@]}"; do
    echo "[$((i+1))] ${STORAGE_LIST[$i]}"
done

# Leitura da escolha
while true; do
    read -p "Escolha o storage pelo número: " STORAGE_NUM
    if [[ "$STORAGE_NUM" =~ ^[0-9]+$ ]] && [ "$STORAGE_NUM" -ge 1 ] && [ "$STORAGE_NUM" -le ${#STORAGE_LIST[@]} ]; then
        DEST_STORAGE="${STORAGE_LIST[$((STORAGE_NUM-1))]}"
        break
    else
        echo "Opção inválida. Tente novamente."
    fi
done

info "Storage escolhido: $DEST_STORAGE"

# Valida storage
if ! ssh root@"$DEST_NODE" "pvesm status --content rootdir | awk '{print \$1}' | grep -qx \"$DEST_STORAGE\""; then
    erro "O storage '$DEST_STORAGE' não suporta containers (rootdir) ou não existe."
fi

# === Restauração ===
info "Restaurando CT no destino com ID ${NEWCTID}, storage ${DEST_STORAGE}..."
ssh root@"$DEST_NODE" "pct restore $NEWCTID /tmp/$(basename "$BACKUP_FILE") --storage $DEST_STORAGE --force 1" || erro "Falha ao restaurar o CT no destino."

info "Migração concluída com sucesso!"
echo "CT $CTID do nó local foi restaurado no nó $DEST_NODE como CT $NEWCTID (storage: $DEST_STORAGE)."

