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

Instale o rclone e configure ao menos um remote:

```bash
omarchy-pkg-add rclone
rclone config
```

Clone este repositório e execute o instalador:

```bash
git clone https://github.com/gustavx404/omarchy-backup-plugin.git ~/Projects/omarchy-backup-plugin
cd ~/Projects/omarchy-backup-plugin
./install.sh
```

O instalador adiciona o painel, cria o comando `backup_multiplo` e ativa o timer
de usuário de duas em duas horas. Ele não exige remote chamado `Filen`. Em uma
instalação nova, se o remote legado `Filen:` não estiver configurado, o painel
começa sem syncs: abra **+ Novo sync** e crie o primeiro. Instalações antigas
com `Filen:` mantêm a migração do sync pessoal existente.

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

```bash
backup_multiplo status
backup_multiplo status --json
backup_multiplo snapshot
backup_multiplo --dry-run
backup_multiplo syncs list --json
backup_multiplo syncs remotes --json
backup_multiplo syncs run ID
backup_multiplo syncs run ID --resync --mode newer
```

`syncs run ID --resync --mode` aceita `newer`, `path1` ou `path2`. `newer`
preserva o arquivo mais recente em conflitos; `path1` prioriza a origem local e
`path2` prioriza o destino remoto. O baseline de um job é independente dos
demais.

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

## Desinstalar

```bash
./install.sh --uninstall
```

O desinstalador remove timer, serviço, link e painel; mantém arquivos
sincronizados, configuração dos jobs, logs e estado.
