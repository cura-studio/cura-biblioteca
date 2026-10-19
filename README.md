<p align="center"><img src="assets/cura-marca-tight.svg" width="140"></p>

# biblioteca cura

A biblioteca cura reúne os plugins, fontes e template do método cura para SketchUp. Este instalador baixa sempre a versão mais recente diretamente do GitHub — não é preciso reinstalar manualmente a cada atualização; basta rodar o instalador de novo quando quiser atualizar (ele conserta a instalação existente).

## atualização 10.3.1: reinstalação sem erro nas fontes

No Windows, rodar o instalador de novo com as fontes da Biblioteca já
instaladas terminava com erro de "arquivo em uso" nas fontes, embora elas não
tivessem mudado. Agora o instalador reconhece a fonte idêntica, mantém a que já
está no computador e conclui sem erro. A atualização automática roda o mesmo
instalador e também deixa de repetir esse erro. Plugin, template, fontes e
Photoshop seguem os mesmos arquivos da 10.3.0.

## atualização 10.3.0: Ferramentas 1.1.0

A Biblioteca distribui o CURA Ferramentas 1.1.0, assinado e protegido pelo
portal oficial SketchUp. O painel reúne 18 ferramentas. A gratuidade termina
em 30/06/2027 às 00:00 de Brasília. A ativação futura por e-mail depende de
uma integração posterior com o backend CURA.

O atualizador da Biblioteca, quando registrado e ativo, verifica no login e
diariamente; se o SketchUp estiver aberto, adia para o próximo disparo. Quem
instalou somente um RBZ antigo sem esse atualizador deve executar o instalador
da Biblioteca uma vez. O botão de atualização dentro do plugin é uma alternativa
e exige clique e reinício do SketchUp. O rodapé do plugin deve mostrar 1.1.0.
Publicação não confirma instalação em cada computador.

A atualização preserva instalações que pertencem à Extension Warehouse,
inclusive em recuperação e desinstalação com recibos antigos. O canal
Warehouse usa a revisão e a atualização nativas do SketchUp; sua publicação
é uma etapa separada da release da Biblioteca.

O template CURA.skp, as fontes e o Photoshop permanecem com os mesmos arquivos
da Biblioteca 10.2.0. O template usa formato SketchUp 2018 e aparece em
**Meus templates**. O instalador preserva o template padrão e mantém backup
de arquivo diferente no mesmo destino. As configurações antigas de V-Ray
não foram convertidas nem validadas para V-Ray 7.

## instalação

### windows

1. Baixe o instalador mais recente (`BibliotecaCURA-Setup.exe`) na [página de releases](https://github.com/cura-studio/cura-biblioteca/releases/latest).
2. Execute o arquivo baixado.
3. O Windows SmartScreen provavelmente vai avisar que o programa é de um editor desconhecido (o instalador ainda não tem assinatura de código). Clique em **Mais informações** e depois em **Executar assim mesmo**.
4. Siga o assistente. Não é preciso ser administrador — a instalação é só para o seu usuário.
5. Se o SketchUp estiver aberto, feche-o quando o instalador pedir.
6. Ao final, abra o SketchUp e confira o menu **Extensões** para ver o `cura | ferramentas` instalado.

### mac

Abra o Terminal e cole a linha abaixo:

```
/bin/bash -c "$(curl -fsSL https://github.com/cura-studio/cura-biblioteca/releases/latest/download/install.sh)"
```

O script baixa o manifest mais recente e instala os plugins e fontes em todas as versões do SketchUp encontradas no seu Mac.

## instalações pela Extension Warehouse

O Ferramentas instalado pela Extension Warehouse é mantido pela Warehouse. A Biblioteca preserva seus arquivos, inclusive ao atualizar ou desinstalar uma Biblioteca antiga que ainda tenha recibos desses arquivos. Cada versão do SketchUp tem seu próprio canal: é possível usar Warehouse em uma e Biblioteca em outra. A identidade de acesso permanece fora da pasta de plugins.

Essa proteção depende dos scripts novos. Computadores que ainda usam um instalador ou cache antigo precisam receber a versão atual pelo Latest ou executar o instalador atual uma vez, com o SketchUp fechado. A Biblioteca não converte canais automaticamente; metadados ilegíveis, inválidos ou desconhecidos geram aviso e preservação dos arquivos para conferência.

## desinstalar

**Windows:** abra Configurações > Aplicativos (ou o Painel de Controle > Programas) e desinstale "Biblioteca CURA" como qualquer outro programa.

**Mac:** cole a mesma linha do Terminal usada na instalação, acrescentando `-- --uninstall` no final:

```
/bin/bash -c "$(curl -fsSL https://github.com/cura-studio/cura-biblioteca/releases/latest/download/install.sh)" -- --uninstall
```

Os dois modos listam exatamente o que vão remover antes de agir.

## limpar sketchup

Tira do SketchUp todos os plugins que **não** são do cura — qualquer coisa que não comece com `cura_` (os plugins do cura) nem com `su_` (as ferramentas nativas do próprio SketchUp, como Sandbox e Componentes Dinâmicos) —, em todas as versões instaladas.

**Nunca apaga**: move tudo para `Documentos/cura-plugins-removidos/<data-hora>/SketchUp <ano>/`. Se o aluno se arrepender, é só arrastar de volta. Isso é deliberado — a pasta `Plugins/` contém plugins de terceiros que o aluno comprou ou instalou por conta (`TT_Lib2`, por exemplo, é dependência do Solid Inspector², Vertex Tools e QuadFace Tools).

Pede confirmação e não roda em modo silencioso.

**Windows:** `powershell -ExecutionPolicy Bypass -File install.ps1 -Limpar`

**Mac:**

```
/bin/bash -c "$(curl -fsSL https://github.com/cura-studio/cura-biblioteca/releases/latest/download/install.sh)" -- --limpar
```

## fontes

`payload/fonts.zip` é gerado por `tools/make_fonts.py` (precisa de `fonttools`, só em build). Desde a decisão do João de 2026-08-26, o default é o **split**: o zip público (`--out`, `payload/fonts.zip`) leva só as famílias **livres** (OFL); as 5 clássicas (Helvetica Neue, Futura, Avant Garde, Garamond, Minion — Adobe/Linotype, licença comprada, sem direito de redistribuição pública) ficam **fora**, porque `payload/fonts.zip` é asset de release de um repositório **público** — qualquer um baixa com `curl`, sem login e sem Hotmart.

```
python3 tools/make_fonts.py <pasta-das-classicas> --google <pasta-das-google-fonts>
python3 tools/make_manifest.py
```

São duas pastas: o argumento posicional passa pela allowlist das 5 clássicas (helvetica neue, futura, avant garde, garamond, minion) e o `--google` entra inteiro — mesmo sem `--out-classicas`, a pasta das clássicas continua obrigatória (é ela que decide o que **não** entra no zip público). Esquecer o `--google` regera um `fonts.zip` com metade das famílias e ninguém percebe — o sha256 muda e o CI publica normal. Sem `--out-classicas`, o comando acima só avisa no terminal quais famílias ficaram de fora e imprime o comando pronto pra gerar o zip privado — nunca gera o zip das clássicas sozinho. O zip público atual tem 17 arquivos de fonte (`poppins.ttc` + 16 `.ttf` variáveis do Google), mais o `names.json` e a pasta `licencas/` com as 10 OFL.

Passe `--out-classicas` pra gerar também o zip privado, na mesma rodada: o zip de `--out` continua só com as livres, e as clássicas vão pro zip separado, pro mesmo canal privado das texturas/HDRIs (nunca sobe pro GitHub nem pro release).

```
python3 tools/make_fonts.py <pasta-das-classicas> --google <pasta-das-google-fonts> \
  --out payload/fonts.zip --out-classicas ~/entrega/fontes-classicas.zip
```

Ele faz a curadoria pela família tipográfica declarada dentro do arquivo (nome de arquivo mente, name table não). Família com 3 ou mais arquivos vira um único `.ttc`; com 1 ou 2 arquivos fica como o fabricante entregou. E gera o `names.json` que o `install.ps1` usa pra registrar a fonte no Windows. Sem esse `names.json`, o Windows só expõe a primeira face de cada `.ttc`.

O campo `fonts.url` do manifest é **reservado**: existe pra espelhar o bloco de plugins, mas nenhum dos dois instaladores lê ele hoje — o `fonts.zip` sempre vem do asset da release. Trocar isso é trabalho de instalador, não de manifest.

## publicar uma versão

Os uploads abertos de Biblioteca para o Signing Portal e de Warehouse devem permanecer **fora do checkout público**, inclusive antes de commit e push. `tools/prepare_channels.py --biblioteca <upload-biblioteca.rbz> --warehouse <upload-warehouse.rbz> --source-commit <sha-completo> --output <pasta-privada-nova>` confere canais, versão e igualdade dos motores, prepara cópias privadas e registra hashes no plano de entrega. Ele não assina, envia ou publica; a aprovação e a publicação da Warehouse continuam dependendo do portal e de seus comprovantes. Nunca coloque esses uploads abertos, código-fonte ou source archives nos assets da Biblioteca. Um gate posterior de CI não impede a exposição que já ocorreu em um commit público.

Somente o **RBZ do canal Biblioteca devolvido protegido e validado pelo Signing Portal**, com o hash exato conferido, pode entrar em `payload/` e na release pública. Preserve os bytes retornados pelo portal: não reempacote nem substitua esse artefato pelo upload aberto ou pelo pacote Warehouse.

Três números decidem se o aluno recebe a atualização — `biblioteca_version`, `plugins[].version` e a tag — e os três são editados **na mão**, em lugares diferentes. `make_manifest.py` não bumpa nenhum deles: só recalcula sha256 e confere.

1. Copie exclusivamente o RBZ Biblioteca protegido e validado descrito acima (e o `fonts.zip`, se mudou) para `payload/` e **versione**: `git status` não pode mostrar nada de `payload/` como untracked. O CI publica com `fail_on_unmatched_files: true` e falha se faltar asset.
   - Mudou o cura upscaler? Rode `python3 tools/make_photoshop.py <fonte-jsx>`: ele regenera `payload/photoshop.zip` **e** `payload/CuraUpscaler.jsx` (link de resgate da página do curso) **juntos**, e os dois têm que ser versionados. Não regerar os dois é release quebrada na cara do aluno — o gate do CI compara o sha256 do `.jsx` solto com o de dentro do zip e reprova se divergirem.
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
curl -sI https://github.com/cura-studio/cura-biblioteca/releases/latest/download/BibliotecaCURA-Setup.exe | grep -i '^location'
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
