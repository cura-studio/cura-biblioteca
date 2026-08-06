<p align="center"><img src="assets/cura-marca-tight.svg" width="140"></p>

# biblioteca cura

A biblioteca cura reúne os plugins e fontes do método cura para SketchUp. Este instalador baixa sempre a versão mais recente diretamente do GitHub — não é preciso reinstalar manualmente a cada atualização; basta rodar o instalador de novo quando quiser atualizar (ele conserta a instalação existente).

## beta

A biblioteca está em **beta**: o instalador é estável, mas o plugin `cura | ferramentas` ainda está em teste e recebe correções com frequência. Como o instalador se atualiza sozinho, quem instalar agora recebe cada correção automaticamente — não é preciso reinstalar.

O aviso de beta aparece em quatro lugares e sai todo de uma vez quando a versão for promovida:

| Onde | O quê |
|---|---|
| `scripts/install.sh` | variável `BETA_NOTE` |
| `scripts/install.ps1` | linha `Write-Host` marcada com `# aviso de beta` |
| `windows/installer.iss` | `WelcomeLabel2` e `FinishedLabel` |
| `cura-ferramentas/src/cura_ferramentas.rb` | prefixo `VERSAO BETA` em `ex.description` |

## instalação

### windows

1. Baixe o instalador mais recente (`BibliotecaCURA-Setup.exe`) na [página de releases](https://github.com/joaotegoni/cura-biblioteca/releases/latest).
2. Execute o arquivo baixado.
3. O Windows SmartScreen provavelmente vai avisar que o programa é de um editor desconhecido (o instalador ainda não tem assinatura de código). Clique em **Mais informações** e depois em **Executar assim mesmo**.
4. Siga o assistente. Não é preciso ser administrador — a instalação é só para o seu usuário.
5. Se o SketchUp estiver aberto, feche-o quando o instalador pedir.
6. Ao final, abra o SketchUp e confira o menu **Extensões** para ver o `cura | ferramentas` instalado.

### mac

Abra o Terminal e cole a linha abaixo:

```
/bin/bash -c "$(curl -fsSL https://github.com/joaotegoni/cura-biblioteca/releases/latest/download/install.sh)"
```

O script baixa o manifest mais recente e instala os plugins e fontes em todas as versões do SketchUp encontradas no seu Mac.

## desinstalar

**Windows:** abra Configurações > Aplicativos (ou o Painel de Controle > Programas) e desinstale "Biblioteca CURA" como qualquer outro programa.

**Mac:** cole a mesma linha do Terminal usada na instalação, acrescentando `-- --uninstall` no final:

```
/bin/bash -c "$(curl -fsSL https://github.com/joaotegoni/cura-biblioteca/releases/latest/download/install.sh)" -- --uninstall
```

Os dois modos listam exatamente o que vão remover antes de agir.

## limpar sketchup

Tira do SketchUp todos os plugins que **não** são do cura — qualquer coisa que não comece com `cura_` (os plugins do cura) nem com `su_` (as ferramentas nativas do próprio SketchUp, como Sandbox e Componentes Dinâmicos) —, em todas as versões instaladas.

**Nunca apaga**: move tudo para `Documentos/cura-plugins-removidos/<data-hora>/SketchUp <ano>/`. Se o aluno se arrepender, é só arrastar de volta. Isso é deliberado — a pasta `Plugins/` contém plugins de terceiros que o aluno comprou ou instalou por conta (`TT_Lib2`, por exemplo, é dependência do Solid Inspector², Vertex Tools e QuadFace Tools).

Pede confirmação e não roda em modo silencioso.

**Windows:** `powershell -ExecutionPolicy Bypass -File install.ps1 -Limpar`

**Mac:**

```
/bin/bash -c "$(curl -fsSL https://github.com/joaotegoni/cura-biblioteca/releases/latest/download/install.sh)" -- --limpar
```

## fontes

`payload/fonts.zip` é gerado por `tools/make_fonts.py` (precisa de `fonttools`, só em build). O default é o **pacote completo** — clássicas e Google no mesmo zip, que é o que o instalador entrega hoje:

```
python3 tools/make_fonts.py <pasta-das-classicas> --google <pasta-das-google-fonts>
python3 tools/make_manifest.py
```

São duas pastas: o argumento posicional passa pela allowlist das 5 clássicas (helvetica neue, futura, avant garde, garamond, minion) e o `--google` entra inteiro. Esquecer o `--google` regera um `fonts.zip` com metade das famílias e ninguém percebe — o sha256 muda e o CI publica normal. O zip atual tem 22 arquivos de fonte (os 5 `.ttc` clássicos + `poppins.ttc` + 16 `.ttf` variáveis do Google), mais o `names.json` e a pasta `licencas/` com as 10 OFL.

Passar `--out-classicas` liga o **modo split**: o zip de `--out` fica só com as famílias livres (OFL) e as clássicas vão pra um zip à parte, pro mesmo canal privado das texturas/HDRIs.

```
python3 tools/make_fonts.py <pasta-das-classicas> --google <pasta-das-google-fonts> \
  --out payload/fonts-livres.zip --out-classicas ~/entrega/fontes-classicas.zip
```

O split existe porque `payload/fonts.zip` é asset de release de um repositório **público**: qualquer um baixa com um `curl`, sem login e sem Hotmart, e as clássicas são Adobe/Linotype com "all rights reserved" dentro do próprio binário. Enquanto essa decisão de licenciamento não fecha, o default é o pacote completo — e o build imprime um aviso a cada rodada lembrando disso.

Ele faz a curadoria pela família tipográfica declarada dentro do arquivo (nome de arquivo mente, name table não). Família com 3 ou mais arquivos vira um único `.ttc`; com 1 ou 2 arquivos fica como o fabricante entregou. E gera o `names.json` que o `install.ps1` usa pra registrar a fonte no Windows. Sem esse `names.json`, o Windows só expõe a primeira face de cada `.ttc`.

O campo `fonts.url` do manifest é **reservado**: existe pra espelhar o bloco de plugins, mas nenhum dos dois instaladores lê ele hoje — o `fonts.zip` sempre vem do asset da release. Trocar isso é trabalho de instalador, não de manifest.

## publicar uma versão

Três números decidem se o aluno recebe a atualização — `biblioteca_version`, `plugins[].version` e a tag — e os três são editados **na mão**, em lugares diferentes. `make_manifest.py` não bumpa nenhum deles: só recalcula sha256 e confere.

1. Copie o `.rbz` novo (e o `fonts.zip`, se mudou) para `payload/` e **versione**: `git status` não pode mostrar nada de `payload/` como untracked. O CI publica com `fail_on_unmatched_files: true` e falha se faltar asset.
2. Edite `manifest.json` na mão:
   - `plugins[0].version` = a constante `VERSION` de dentro do `.rbz`. É o que o updater dentro do plugin compara: errado pra menos, o banner de atualização nunca aparece; pra mais, ele aparece pra sempre e reinstalar não limpa.
   - `biblioteca_version` = a versão nova da biblioteca (a tag sem o `v`). É o **único** critério de no-op dos instaladores: se não mudar, todo mundo responde "já está atualizada" e o payload novo nem é baixado.
3. `python3 tools/make_manifest.py` — recalcula os sha256 e quebra se `roots` ou `plugins[].version` divergirem do conteúdo real do `.rbz`.
4. Commit.
5. Tag **sem sufixo**: `git tag v9.2.0 && git push --tags`.
6. O Actions confere tag ↔ manifest ↔ rbz, compila o instalador do Windows e publica a release.

### gate pré-GA: fontes num Windows real

Antes de promover a biblioteca de beta pra GA, testar as fontes num Windows de verdade: abrir o seletor de fonte do Photoshop **e** do SketchUp e anotar quantos pesos aparecem por família Google (fonte variável pode expor só 1 peso em app GDI). Se cortar, gerar os estáticos com o instancer (`python3 -m fontTools.varLib.instancer`) e reempacotar.

### a armadilha do hífen — leia antes de tagear

> **Regra dura: tag com hífen = prerelease = ninguém recebe.**

`release.yml` faz `prerelease: contains(github.ref_name, '-')`, e prerelease **nunca** é servida em `/releases/latest/download` — que é o único endereço que o `install.sh`, o `install.ps1`, o `installer.iss` e o updater de dentro do plugin conhecem. Tagear `v9.2.0-beta` dá: CI verde, release bonita na página, **zero aluno recebe**.

Todas as seis tags que já existem no repo terminam em `-rcN`: a memória muscular aponta 100% pro formato errado. Por isso o gate do CI recusa qualquer sufixo que não seja `-rcN` e avisa em amarelo quando é `-rcN`.

- **release pra valer**: `vX.Y.Z`, sem sufixo.
- **teste de pipeline**: `vX.Y.Z-rcN`, de propósito. Sai invisível pro parque; pra testar, baixe o asset da própria release ou aponte `CURA_BASE_URL` pra `.../releases/download/<tag>`.
- O hífen define só o flag **inicial** — o flag é editável na UI, e é por isso que hoje a `v9.0.1-rc1` (tag com hífen) aparece como Latest: foi promovida na mão. Promover um rc = `gh release edit <tag> --prerelease=false --latest`.

### conferir depois de publicar (30 segundos, sempre)

```
curl -sI https://github.com/joaotegoni/cura-biblioteca/releases/latest/download/BibliotecaCURA-Setup.exe | grep -i '^location'
```

Tem que voltar um **302** com `location` apontando pra `/releases/download/<tag-nova>/`. Se apontar pra uma tag antiga, a release saiu como prerelease e o parque não vai ver nada.

E teste sempre **pelo instalador**, nunca por side-load do `.rbz`: só instalar a partir da release publicada exercita manifest, sha256, limpeza e snapshot juntos.

## reverter (kill switch)

1. **Primeira opção: ir pra frente.** Corrija e tageie uma `vX.Y.Z` nova sem hífen. Resolve sem downgrade e é o único caminho sem efeito colateral.
2. **Freio de emergência** (a versão ruim está quebrando máquina de aluno agora): marque a release ruim como pre-release (`gh release edit <tag> --prerelease=true`) **e apague a tag remota** (`git push --delete origin <tag>`). Sem apagar a tag, um "Re-run all jobs" no Actions republica a release e desfaz o flag. Feito isso, `latest` cai pra release cheia anterior e cada máquina se corrige sozinha no próximo disparo (login ou reserva diária).

Três coisas para saber antes de puxar o freio:

- **Não é passivo.** O rollback mexe na máquina do aluno: `biblioteca_version` diferente não vira no-op, então a instalação roda inteira — apaga os roots e extrai a versão antiga por cima.
- **Ele apaga plugin de terceiro.** Toda release publicada até a 9.1.1 carrega `remove: ["TT_Lib2", "TT_CleanUp", "TT_EdgeTools", ...]`, e o instalador dessas versões aplica a lista apagando de verdade, sem cópia no porão de recuperação. Como o rollback faz a máquina rodar o instalador da release antiga, voltar pra uma delas deleta TT_Lib2/CleanUp/EdgeTools do aluno e quebra Solid Inspector², Vertex Tools e QuadFace Tools. O custo some quando a release cheia anterior for uma com `remove: []`.
- **Onde `latest` cai hoje**: na `v9.0.1-rc1` (biblioteca 9.0.1, plugin 0.8.1). Não existe tag `v9.0.1`, e não é a 9.1.1 — a `v9.1.0-rc1` e a `v9.1.1-rc1` seguem marcadas pre-release. São duas gerações pra trás; pra encurtar o downgrade, promova antes a `v9.1.1-rc1` a release cheia.

## identidade visual

Para mudar o ícone e as imagens do assistente de instalação, edite o logotipo de origem em `assets/` e rode `python3 tools/make_assets.py`. Os binários gerados (`windows/wizard-large.bmp`, `windows/wizard-small.bmp`, `windows/cura.ico`) entram no repositório junto com o resto — não são baixados em tempo de instalação.

## roadmap

- **Assinatura de código** (Windows e Mac): os slots já existem no instalador e no script; falta só o certificado.
- **Plugin por assinatura**: os dois instaladores já honram uma `url` absoluta em `plugins[]` — trocar esse campo por um endpoint autenticado restringe o download a quem tem assinatura ativa, sem mudar o instalador. O mesmo campo em `fonts` é reservado: está no schema, mas ainda não é lido por nenhum dos dois.
