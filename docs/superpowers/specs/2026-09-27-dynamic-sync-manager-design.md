# Gerenciador dinâmico de sincronizações — especificação

## Objetivo

Permitir criar e administrar sincronizações pelo painel do plugin Omarchy Backup, sem editar o script. A configuração deve sobreviver a atualizações do plugin e preservar o sync pessoal atual.

## Decisões confirmadas

- Os syncs ficam em `~/.config/backup-multiplo/syncs.json`, fora do repositório.
- Na primeira utilização, migrar o job atual `~/personal` ↔ `Filen:personal` em modo bidirecional.
- O menu oferece criar, editar, ativar/desativar e remover um sync.
- Cada job configura nome, pasta de origem, destino `remote:pasta`, modo e exclusões.
- Modos: bidirecional (`bisync`), espelho (`sync`, pode apagar arquivos extras no destino) e cópia (`copy`, não apaga no destino).
- Todos os jobs ativos usam o timer global de duas horas.
- Salvar configuração não inicia sincronização. Executar continua sendo uma ação separada.
- Remover um job apaga somente sua configuração, nunca arquivos da origem ou destino.
- O filtro de segurança existente permanece aplicado por padrão aos syncs pessoais. Os padrões que bloqueiam Vault, arquivos de perfil e segredos não podem ser removidos pela interface.
- O painel informa os riscos do modo escolhido antes de permitir execução manual; a confirmação é obrigatória para espelho e primeiro baseline bidirecional.
- A execução manual é por job. O baseline inicial ou recriado de um job não altera o baseline dos demais; o padrão de conflito continua sendo “mais recente”.
- O destino oferece seleção dinâmica dos remotes que já estão configurados no rclone, incluindo nome e tipo, com atualização manual. O menu não cria credenciais nem remotes; a configuração/autorização do provider continua no próprio rclone.

## Experiência no painel

Uma seção “Sincronizações” lista nome, origem, destino, modo e último estado conhecido. Ações por item permitem editar, pausar/retomar e remover. “Adicionar sync” abre um formulário compacto com campos validados, seletor dos remotes configurados no rclone, caminho de destino e exclusões adicionais. O seletor obtém nome e tipo de `rclone listremotes --json` e oferece atualizar a lista. A tela de revisão mostra os caminhos e o efeito do modo; salvar atualiza a configuração sem rodar o rclone. Uma ação explícita inicia a execução.

O fluxo de adicionar e editar permanece no painel atual do Quickshell e acompanha seus estados visuais. O teclado deve continuar permitindo navegar, ativar e fechar o painel. Erros de validação ou gravação aparecem no próprio formulário.

## Configuração e execução

O JSON guarda uma lista versionada de jobs com identificador estável e campos: `id`, `name`, `source`, `destination`, `mode`, `enabled` e `exclude`. O arquivo tem permissões privadas (`0600`), gravação atômica e validação estrita de schema. Nenhuma credencial do rclone é copiada para ele. Exclusões configuráveis só acrescentam padrões `-` ao filtro; a interface e o CLI rejeitam regras de inclusão (`+`) ou negação de filtros (`!`). Destinos sobrepostos são proibidos entre jobs para impedir que uma gravação de um job sobrescreva ou apague o conteúdo controlado por outro.

O script carrega jobs ativos do arquivo e mantém um fallback compatível com a definição atual se o arquivo ainda não existir. Um arquivo inválido interrompe o runner com erro claro; não pode cair silenciosamente no job legado. Cada job usa uma cópia estável e privada do filtro global mais exclusões adicionais; mudanças de filtro exigem baseline individual como o rclone determina. Destinos sobrepostos entre jobs são rejeitados. Fontes devem ser pastas absolutas existentes; `/`, `$HOME`, pastas protegidas conhecidas (rclone, SSH/GPG, perfis completos de navegadores, Vault) e caminhos que incluam o diretório de arquivo morto são rejeitados. O arquivo global de filtros também deve bloquear esses conteúdos independentemente do diretório de origem.

O estado JSON consumido pelo painel inclui os jobs configurados sem credenciais. Os arquivos atuais de status e histórico continuam funcionando; os registros identificam cada job, sem depender somente do destino.

## Segurança e limites

- Nunca montar comandos de shell concatenando valores da interface; usar argumentos separados.
- Validar remote com `rclone listremotes`, mas não abrir nem copiar `rclone.conf`.
- Ao enumerar remotes, expor somente os campos `name` e `type` do JSON do rclone; descartar descrição, origem e demais atributos.
- Rejeitar destino sem `remote:` e identificadores de remote desconhecidos.
- Não executar sync ao criar, editar, ativar ou remover jobs.
- Preservar locks, timeout, limites de exclusão, arquivo morto e tratamento de conflitos existentes.
- `sync` pode apagar conteúdo extra do destino; exibir aviso claro e exigir confirmação antes da execução.
- `bisync` pode propagar alterações dos dois lados; baseline inicial segue confirmação explícita.
- Baseline e execução manual são escopados ao ID do job, para não recriar os baselines dos outros syncs. O vencedor padrão é o arquivo mais recente.
- Desativar um job não apaga seus dados ou seu baseline.

## Critérios de aceitação

1. Instalação sem configuração prévia inicializa o arquivo com o job atual Filen, sem executar rclone.
2. É possível criar, editar, pausar/retomar e remover jobs pelo painel; as alterações persistem após reiniciar o painel.
3. Um job inválido não altera o arquivo de configuração existente.
4. Caminhos com espaços e caracteres Unicode são preservados como argumentos individuais.
5. Jobs desativados não são executados pelo timer.
6. Modo cópia nunca solicita remoções; espelho informa e confirma possíveis remoções; bidirecional exige baseline confirmado antes da primeira execução.
7. Os filtros globais de segurança continuam aplicados em todo job.
8. O status do painel identifica cada job configurado e apresenta seu último resultado.
9. Nenhum fluxo de criação ou edição executa sincronização automaticamente.
10. Remotes adicionados no rclone aparecem ao atualizar a lista do menu, sem revelar atributos de configuração.
