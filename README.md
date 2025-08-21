# Scripts de Gerenciamento de Proxmox

Este repositório contém uma coleção de scripts de shell projetados para simplificar tarefas comuns de gerenciamento em ambientes Proxmox.

---

## Scripts Disponíveis

### `backup_cts.sh`
Cria um backup local de todos os contêineres (CTs) existentes no sistema. Este script é ideal para rotinas de segurança e para garantir a integridade dos dados dos seus contêineres.

### `create_ct.sh`
Um script interativo para criar novos contêineres. Ele solicita cada parâmetro necessário para a criação do CT, como ID, tipo de SO, tamanho do disco, memória, e outros, tornando o processo rápido e menos propenso a erros.

### `create_user.sh`
Cria um novo usuário e o adiciona ao grupo `sudo` em todos os contêineres ativos. Isso simplifica o gerenciamento de acesso e a configuração de novos usuários com privilégios administrativos.

### `create_vm.sh`
Similar ao script de criação de CT, este script cria uma nova máquina virtual (VM) perguntando por cada parâmetro de configuração, como tipo de SO, disco, RAM, e rede.

### `migrate_ct.sh`
Projetado para migrar um contêiner de um servidor Proxmox para outro, mesmo que os servidores não estejam em um cluster. Ele realiza a migração usando uma combinação de backup e `scp` (Secure Copy Protocol) para transferir os dados com segurança.

---

## Como Usar

1.  **Clone o repositório:**
    ```sh
    git clone https://github.com/gndcyber/scripts-proxmox.git
    cd scripts-proxmox
    ```

2.  **Execute os scripts:**
    Certifique-se de que os scripts tenham permissão de execução:
    ```sh
    chmod +x *.sh
    ```
    Agora você pode executar qualquer script:
    ```sh
    ./nome_do_script.sh
    ```

## Contribuições

Contribuições são sempre bem-vindas! Sinta-se à vontade para abrir uma *issue* ou enviar um *pull request* com melhorias, correções de bugs ou novos scripts.
