# Gerenciador dinâmico de syncs — plano de implementação

> **For agentic workers:** execute as tarefas sequencialmente nesta sessão. Não crie commits.

**Objetivo:** gerenciar syncs pessoais pelo painel Omarchy Backup e executá-los pelo timer global existente.

**Arquitetura:** `backup_multiplo.sh` mantém e valida a configuração privada versionada em `~/.config/backup-multiplo/syncs.json`, migra o job Filen atual e carrega jobs ativos no runner. O status JSON expõe jobs configurados e resultados. `BackupDashboard.qml` oferece lista e formulário local para criar, editar, ativar/desativar, remover e executar explicitamente.

**Stack:** Bash, jq, rclone, Quickshell QML e systemd --user já usados pelo projeto.

**Especificação:** `docs/superpowers/specs/2026-09-27-dynamic-sync-manager-design.md`.

## Restrições globais

- Configuração fica fora do repositório em `~/.config/backup-multiplo/syncs.json`, permissões `0600`, gravação atômica e schema versionado.
- Job inicial continua sendo `~/personal` ↔ `Filen:personal` em modo bisync.
- Modos aceitos: `bisync`, `sync`, `copy`; timer global continua em duas horas.
- Todas as tarefas respeitam filtros de segurança globais e exclusões adicionais por job.
- Salvar, ativar/desativar ou remover não chama rclone; remoção nunca apaga arquivos do usuário.
- Comandos QML passam argumentos em vetor, sem shell concatenado.
- Baseline manual é limitado a um único ID de job; padrão de conflito é o lado mais recente.
- Exclusões de job são apenas negativas e nunca podem remover os filtros globais de segurança.
- O menu consulta `rclone listremotes --json`, expõe somente nome e tipo, e permite atualizar a lista de remotes configurados.
- Não incluir credenciais rclone no JSON/status.
- Não criar nem executar testes automatizados; validação estática apenas, conforme instrução do usuário.
- Não criar commit nem fazer push.

## Foco de revisão

- JSON inválido ou campo malformado: rejeitar sem substituir a configuração válida.
- Caminho com espaço/Unicode: permanecer um argumento único no processo QML/rclone.
- Remote ausente ou inválido: não habilitar/gravar job executável.
- Caminhos sobrepostos: impedir dois destinos de escrita `sync`/`bisync` concorrentes.
- `sync` e primeira execução `bisync`: mostrar confirmação apropriada antes de executar.

---

### Tarefa 1: armazenamento e gestão de configuração

**Arquivos:** `backup_multiplo.sh`.

**Interfaces:**
- Produz `syncs list --json`, `syncs upsert --json <objeto>`, `syncs set-enabled <id> <0|1>` e `syncs remove <id>`.
- Produz `syncs remotes --json` com uma lista de `{name,type}`, filtrada localmente a partir do JSON do rclone.
- Formato raiz `{version:1,jobs:[...]}`. Job: `{id,name,source,destination,mode,enabled,exclude}`.
- `status --json` inclui `syncs`, sem segredo, além dos campos já existentes.

- Inicialize config atomicamente com o job Filen atual se o arquivo ainda não existir.
- Valide versão, IDs, strings, modos, diretório de origem absoluto existente, destino `remote:path`, tamanho e padrões de exclusão negativos; confirme remote com `rclone listremotes` ao salvar.
- Rejeite `/`, `$HOME`, origem sob locais protegidos conhecidos (rclone, SSH/GPG, perfis de navegador, Vault), arquivo morto como origem, ID duplicado, destino vazio e sobreposição de destinos de quaisquer dois jobs.
- Ao retornar remotes, projete a resposta para `name` e `type`; não devolva descrição, origem nem opções do rclone.
- Grave em arquivo temporário no mesmo diretório, aplique `0600` e renomeie atomicamente.
- Use fallback legado somente se o arquivo ainda não existir e a inicialização ainda não ocorreu; JSON inválido deve interromper execução sem acionar o fallback.
- Valide sintaxe com `bash -n`; faça inspeção dirigida das funções de validação e serialização.

### Tarefa 2: integração de jobs ao runner e status

**Arquivos:** `backup_multiplo.sh`, `rclone-filter.txt`.

**Consome:** configuração e funções de Tarefa 1.

**Produz:** runner executa somente jobs habilitados; status por job inclui ID, nome, origem, destino, modo, habilitado e último resultado.

- Substitua o array estático por jobs lidos do JSON e preserve migração do job pessoal atual.
- Combine exclusões adicionais com o filtro global de segurança sem permitir reativar caminhos bloqueados.
- Expanda o filtro global para bloquear locais sensíveis conhecidos independente do caminho de origem.
- Gere atomicamente uma cópia estável `0600` do filtro por ID em `$STATE_DIR/filters/`; preserve ao lado o `.md5` que o rclone usa para detectar mudanças e exigir baseline.
- Use arquivos de arquivo-morto separados por job para bisync e mantenha locks/limites de exclusão existentes.
- Garanta comando de execução manual por ID, inclusive resync do baseline desse único job, sem afetar os demais.
- Valide sintaxe e revise que status não contém credenciais.

### Tarefa 3: painel de gerenciamento

**Arquivos:** `omarchy-plugin/BackupDashboard.qml`.

**Consome:** `status --json.syncs` e comandos de gestão de Tarefa 1.

**Comandos:** `syncs run <id>`, `syncs run <id> --resync --mode newer|path1|path2` e `syncs remotes --json`.

**Produz:** formulário no painel para adicionar/editar job; lista com estado e ações de ativar/desativar, remover e executar.

- Adicione campos nome, origem, remote selecionado, caminho de destino, modo e exclusões; use `TextArea` para padrões separados por linha.
- Ao abrir/criar/editar, carregar remotes configurados do rclone; botão atualizar recarrega nomes/tipos e nunca exibe atributos sensíveis.
- Envie comandos como arrays de argumentos com valores QML tratados como dados; capture stdout/stderr e reporte erros no formulário.
- Validar campos obrigatórios antes de chamar o script; atualizar painel após salvar com sucesso.
- Confirme remoção de configuração; a mensagem esclarece que arquivos continuam nos dois lados.
- Exiba aviso destacado para espelho (pode apagar extras) e bisync (propaga alterações); execução sempre explícita.
- Preserve foco, rolagem, navegação de teclado e dimensões compactas do painel; usar campos/padrões Quickshell existentes.
- Faça revisão de sintaxe e inspeção do diff QML; se disponível localmente, use validador oficial do plugin sem instalar dependências.

### Tarefa 4: documentação e revisão final

**Arquivos:** `README.md`.

- Documente gerenciamento pelo menu, formato/local privado de configuração, modos e risco de exclusão do espelho.
- Atualize a lista de comandos e instalação/migração.
- Execute validações estáticas específicas (bash -n, jq, validador de plugin quando disponível), `git diff --check` e revisão completa do diff.
- Não instale no diretório do usuário nem reinicie Quickshell nesta etapa; isso exige autorização de escrita fora do workspace.
- Registre resultados e limitações sem criar commit.
