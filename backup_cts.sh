#!/bin/bash

# ======= CONFIGURAÇÕES GERAIS =======
STORAGE_CONFIG_PATH="/etc/pve/storage.cfg"
DIAS=2
COMPRESS="zstd"
LOG_FILE="/var/log/backup_cts.log"

VERDE="\e[32m"
VERMELHO="\e[31m"
AMARELO="\e[33m"
NORMAL="\e[0m"
# ====================================

echo -e "--- ${AMARELO}Início do backup: $(date '+%Y-%m-%d %H:%M:%S')${NORMAL} ---" | tee -a "$LOG_FILE"
echo -e "${AMARELO}[*] Buscando storages do tipo 'dir' em $STORAGE_CONFIG_PATH...${NORMAL}" | tee -a "$LOG_FILE"

# Extrai todos os IDs de storages do tipo 'dir'
# O `grep -oP` busca por "dir:" seguido de um espaço e captura o ID do storage até o próximo espaço.
STORAGE_IDS=$(grep -oP '^dir:\s\K[^ ]+' "$STORAGE_CONFIG_PATH")

if [ -z "$STORAGE_IDS" ]; then
    echo -e "${VERMELHO}[-] ERRO: Nenhum storage do tipo 'dir' encontrado. O script não pode continuar.${NORMAL}" | tee -a "$LOG_FILE"
    exit 1
fi

echo -e "${AMARELO}[*] Storages encontrados: ${STORAGE_IDS}${NORMAL}" | tee -a "$LOG_FILE"
echo -e "${AMARELO}[*] Listando todos os contêineres para backup (ativos e parados).${NORMAL}" | tee -a "$LOG_FILE"

# Lista todos os IDs de CTs, sem filtro
CT_LIST=$(pct list | awk 'NR>1 {print $1}')

if [ -z "$CT_LIST" ]; then
    echo -e "${AMARELO}[!] Nenhum contêiner (CT) encontrado para fazer backup.${NORMAL}" | tee -a "$LOG_FILE"
else
    for CTID in $CT_LIST; do
        echo -e "\n${AMARELO}[+] Iniciando backup do CT $CTID...${NORMAL}" | tee -a "$LOG_FILE"

        # Tenta fazer o backup em todos os storages encontrados
        BACKUP_SUCESSO=0
        for STORAGE_ID in $STORAGE_IDS; do
            echo -e "${AMARELO}[+] Tentando backup para o storage '$STORAGE_ID'...${NORMAL}" | tee -a "$LOG_FILE"
            if vzdump $CTID --storage "$STORAGE_ID" --mode snapshot --compress "$COMPRESS" --quiet 1 2>&1 | tee -a "$LOG_FILE"; then
                echo -e "${VERDE}[+] Backup do CT $CTID concluído com sucesso em '$STORAGE_ID'.${NORMAL}" | tee -a "$LOG_FILE"
                BACKUP_SUCESSO=1
                break # Sai do loop de storages após o primeiro backup bem-sucedido
            else
                echo -e "${VERMELHO}[-] ERRO: Backup do CT $CTID falhou no storage '$STORAGE_ID'. Tentando o próximo...${NORMAL}" | tee -a "$LOG_FILE"
            fi
        done

        if [ "$BACKUP_SUCESSO" -eq 0 ]; then
            echo -e "${VERMELHO}[-] ERRO: Falha ao fazer backup do CT $CTID em todos os storages 'dir' disponíveis.${NORMAL}" | tee -a "$LOG_FILE"
        fi
    done
fi

echo -e "\n${AMARELO}[*] Iniciando a limpeza de backups antigos em todos os storages...${NORMAL}" | tee -a "$LOG_FILE"

for STORAGE_ID in $STORAGE_IDS; do
    echo -e "${AMARELO}[*] Limpeza no storage '$STORAGE_ID'...${NORMAL}" | tee -a "$LOG_FILE"
    # Extrai o caminho de backup para o storage atual
    BACKUP_DIR=$(awk -v storage_id="$STORAGE_ID" '
        /^dir: /{
            current_id=$2
        }
        current_id == storage_id && $1 == "path"{
            print $2
            exit
        }
    ' "$STORAGE_CONFIG_PATH")
    
    if [ -n "$BACKUP_DIR" ]; then
        echo -e "${AMARELO}[*] Removendo backups mais antigos que $DIAS dias em $BACKUP_DIR...${NORMAL}" | tee -a "$LOG_FILE"
        find "$BACKUP_DIR" -type f -name "*.tar.*" -mtime +$DIAS -print -exec rm -f {} \; | tee -a "$LOG_FILE"
    else
        echo -e "${AMARELO}[!] Não foi possível encontrar o caminho para o storage '$STORAGE_ID'. Limpeza ignorada.${NORMAL}" | tee -a "$LOG_FILE"
    fi
done

echo -e "--- ${VERDE}Fim do backup: $(date '+%Y-%m-%d %H:%M:%S')${NORMAL} ---" | tee -a "$LOG_FILE"
echo "" >> "$LOG_FILE"
