# Omarchy Backup

Plugin de backup para Omarchy com painel Quickshell e sincronizações gerenciadas
por [rclone](https://rclone.org/). Escolha qualquer remote que já esteja
configurado no rclone; o projeto não exige uma conta ou provedor específico.

## Recursos

- Painel com estado do timer, atividade recente, logs e ações de backup.
- Criação, edição, pausa, retomada, execução e remoção de syncs no próprio painel.
- Lista automática dos remotes rclone disponíveis, com nome e tipo do provider.
- Três modos: bidirecional (`bisync`), espelho (`sync`) e envio sem remoção (`copy`).
- Filtros globais para excluir credenciais, cofres e perfis completos de navegador.
- Configuração privada em `~/.config/backup-multiplo/syncs.json`; credenciais
  permanecem no rclone.

## Instalar

Instale Python 3.10 ou superior, rclone, rsync e zstd; configure ao menos um remote:

```sh
omarchy pkg add rclone rsync zstd
rclone config
```

Adicione o plugin pelo gerenciador do Omarchy:

```sh
omarchy plugin add https://github.com/gustavx404/backup-omarchy.git --enable
```

Instale o comando e o timer do usuário a partir dos arquivos do plugin:

```sh
PLUGIN="$HOME/.config/omarchy/plugins/local.backup-status"
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
ln -sfn "$PLUGIN/src/omarchy-backup" "$HOME/.local/bin/omarchy-backup"
cp "$PLUGIN/systemd/omarchy-backup.service" "$PLUGIN/systemd/omarchy-backup.timer" \
  "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now omarchy-backup.timer
```

O timer executa de duas em duas horas. O plugin não exige um remote chamado
`Filen`. Em uma instalação nova sem esse remote, abra **+ Novo sync** e crie o
primeiro. Instalações antigas com `Filen:` mantêm a migração do sync pessoal.

## Estrutura do projeto

- `manifest.json`, `BarWidget.qml` e `BackupDashboard.qml`: plugin Omarchy.
- `src/omarchy-backup`: comando e backend Python `omarchy-backup`.
- `src/omarchy_backup/`: módulos de configuração, snapshots, status e execução.
- `src/config-excludes.txt` e `src/rclone-filter.txt`: regras de exclusão.
- `systemd/`: serviço e timer do usuário.
- `tests/`: testes `unittest` do CLI e do backend.

## Criar um sync pelo painel

1. Abra **Backup Omarchy** na barra e pressione **+ Novo sync** no cabeçalho.
2. Informe o nome e uma pasta local existente, como `~/Documents`.
3. Escolha um remote da lista. Para adicionar outro provider, configure-o com
   `rclone config` e use o botão de atualizar remotes no formulário.
4. Informe a pasta dentro do remote, escolha o modo e, se necessário, adicione
   exclusões. Salvar só grava a configuração; não inicia uma cópia.
5. Use **Rodar** para executar. O primeiro baseline do modo bidirecional e as
   execuções do modo espelho pedem confirmação.

O modo `bisync` propaga alterações entre os dois lados. `sync` deixa o destino
igual à origem e pode remover arquivos extras; os arquivos substituídos ou
removidos vão para o arquivo-morto. `copy` envia arquivos sem apagar o destino.
O timer executa todos os syncs ativos a cada duas horas. Pausar ou remover um
sync não apaga os arquivos já existentes.

O seletor mostra somente o nome e o tipo dos remotes já criados. Para autorizar
um provider, use `rclone config`; o plugin não lê nem copia os segredos do
arquivo de configuração do rclone. Se ainda não houver remotes, o formulário
orienta a configurá-los antes de salvar um sync.

## Comandos

```sh
omarchy-backup status
omarchy-backup status --json
omarchy-backup snapshot
omarchy-backup verify
omarchy-backup verify --download
omarchy-backup --dry-run
omarchy-backup syncs list --json
omarchy-backup syncs remotes --json
omarchy-backup syncs run ID
omarchy-backup syncs run ID --resync --mode newer
```

`syncs run ID --resync --mode` aceita `newer`, `path1` ou `path2`. `newer`
preserva o arquivo mais recente em conflitos; `path1` prioriza a origem local e
`path2` prioriza o destino remoto. O baseline de um job é independente dos
demais. `verify` verifica a integridade dos snapshots locais e compara os
arquivos de cada sync ativo com seu destino configurado, sem alterar os dados.
Use `verify --download` para comparar também o conteúdo dos arquivos.

## Destino dos snapshots locais

O painel gera snapshots de configurações portáteis do Omarchy e dos favoritos
dos navegadores. Em **Backups locais → Definir sync e pasta**, escolha um sync e
uma subpasta relativa à origem. Por exemplo, escolhendo `~/personal` e `Backups`,
os arquivos ficam em `~/personal/Backups/Omarchy` e
`~/personal/Backups/Favoritos`; o destino remoto correspondente aparece no
painel. Salvar essa escolha não inicia a sincronização.

Os controles **Omarchy** e **Favoritos** em *Backups locais* ativam cada tipo de
snapshot separadamente. Pausar impede novas gerações; arquivos locais ou remotos
já existentes não são removidos. Em configurações antigas, os dois tipos
permanecem ativos por padrão.

Só favoritos são exportados dos navegadores. Perfis completos, cookies, logins,
senhas e histórico ficam de fora. As configurações usam uma lista positiva e
também passam por uma verificação de possíveis segredos. O sync selecionado
precisa estar ativo para enviar os snapshots; filtros ou exclusões adicionais
desse job também podem impedir o envio.

## Estado e logs

- Configuração: `~/.config/backup-multiplo/syncs.json` (permissão `0600`).
- Estado e filtros por job: `~/.cache/backup_multiplo/`.
- Logs: `~/logs/backup/`.

O rclone exige recriar o baseline de um `bisync` quando os filtros mudam. O
painel identifica esse estado e pede uma decisão antes de iniciar o resync.

## CI e prevenção de regressões

O workflow do GitHub Actions roda em pull requests para qualquer branch, em
pushes para `main` e manualmente. Ele valida a sintaxe Python e roda
`unittest` com diretório pessoal temporário e um rclone falso; nenhum teste
acessa um provider ou altera arquivos do usuário.
As verificações cobrem o parser do painel, `verify` somente leitura, o modo
`copy`, snapshots sem favoritos, sanitização de URLs GTK, bloqueio de chaves em
maiúsculas, destinos de snapshot com tentativa de sair da pasta e permissões da
configuração. O job Gitleaks usa a CLI oficial para examinar todo o histórico
disponível, inclusive commits vindos de outros pais de merge, com os valores
encontrados redigidos na saída.

Rode localmente as mesmas checagens principais antes de publicar:

```sh
python3 -m py_compile src/omarchy_backup/*.py src/omarchy-backup
python3 -m unittest discover -s tests -v
omarchy plugin validate .
```

As verificações automatizadas usam um provider simulado. Antes de uma versão,
valide também o painel com `omarchy plugin validate`, confira a instalação em
uma sessão Omarchy e revise visualmente os tamanhos compactos e responsivos.
Não inclua arquivos de configuração real do rclone, logs pessoais, snapshots
nem credenciais nos testes ou nos artefatos do CI.

## Desinstalar

```sh
systemctl --user disable --now omarchy-backup.timer
rm -f "$HOME/.config/systemd/user/omarchy-backup.service" \
  "$HOME/.config/systemd/user/omarchy-backup.timer" \
  "$HOME/.local/bin/omarchy-backup"
systemctl --user daemon-reload
omarchy plugin remove local.backup-status --yes
```

Isso remove o timer, serviço, link e painel; mantém arquivos sincronizados,
configuração dos jobs, logs e estado.
