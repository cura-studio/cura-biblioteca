// instalar-cura-upscaler.jsx — liga o atalho F2 do Cura Upscaler no Photoshop.
//
// O aluno roda ESTE arquivo uma vez, em Arquivo > Scripts > Procurar (File >
// Scripts > Browse). Ele carrega o action set "cura" (com a action "Cura
// Upscaler" na tecla F2) que o instalador da biblioteca deixou na pasta
// compartilhada, e guarda uma copia do .atn nos Presets do Photoshop do
// usuario pra dar pra recarregar pelo painel Acoes depois.
//
// Rodar de novo NAO duplica nada: o set "cura" que ja estiver carregado e
// descarregado antes, e o novo entra por cima.
//
// Sem acento no fonte de proposito: o Photoshop le o .jsx na codificacao do
// sistema, e acento em literal vira lixo numa maquina com locale diferente do
// nosso. As poucas palavras acentuadas que o aluno LE saem como \uXXXX.

#target photoshop

(function () {
    var PASTAS = [
        "/Users/Shared/CURA-Biblioteca/photoshop",       // mac
        "C:/Users/Public/CURA-Biblioteca/photoshop"      // windows
    ];
    var ATN = "cura-upscaler.atn";
    var JSX = "CuraUpscaler.jsx";
    var SET = "cura";

    var avisos = [];

    // -----------------------------------------------------------------------
    // acha a pasta que o instalador criou. os dois caminhos fixos primeiro
    // (e de la que o .atn abre o .jsx, entao e a fonte da verdade); a pasta
    // deste proprio script por ultimo, pra quem descompactou o zip na mao.
    // -----------------------------------------------------------------------
    function acharPasta() {
        var i, f;
        for (i = 0; i < PASTAS.length; i++) {
            f = new File(PASTAS[i] + "/" + ATN);
            if (f.exists) { return PASTAS[i]; }
        }
        try {
            var aqui = new File($.fileName).parent;
            if (aqui && new File(aqui + "/" + ATN).exists) { return aqui.toString(); }
        } catch (e) {
            // $.fileName indisponivel (script colado no console) — segue sem
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // set de acoes: existe? / remove.
    // app.unloadAction() nao existe nesta versao do Photoshop (testado no
    // 2026: "app.unloadAction nao e uma funcao"), entao o caminho e o
    // ActionManager cru — 'Dlt ' numa referencia por NOME de 'ASet'.
    // -----------------------------------------------------------------------
    function setExiste(nome) {
        try {
            var r = new ActionReference();
            r.putName(charIDToTypeID("ASet"), nome);
            executeActionGet(r);
            return true;
        } catch (e) {
            return false;
        }
    }

    function removerSet(nome) {
        var r = new ActionReference();
        r.putName(charIDToTypeID("ASet"), nome);
        var d = new ActionDescriptor();
        d.putReference(charIDToTypeID("null"), r);
        executeAction(charIDToTypeID("Dlt "), d, DialogModes.NO);
    }

    // -----------------------------------------------------------------------
    // Presets/Actions do usuario da versao corrente do Photoshop:
    //   mac: ~/Library/Application Support/Adobe/Adobe Photoshop 2026/Presets/Actions
    //   win: %APPDATA%\Adobe\Adobe Photoshop 2026\Presets\Actions
    // O nome da pasta sai do proprio app (app.path.name = "Adobe Photoshop
    // 2026"), entao acompanha a versao instalada sem lista fixa. Nao achou os
    // Presets? pula — a copia e conveniencia (recarregar pelo painel Acoes),
    // nao e o que faz o F2 funcionar.
    // -----------------------------------------------------------------------
    function copiarPraPresets(arquivoAtn) {
        var presets = new Folder(Folder.userData + "/Adobe/" + app.path.name + "/Presets");
        if (!presets.exists) { return null; }
        var acoes = new Folder(presets + "/Actions");
        if (!acoes.exists && !acoes.create()) { return null; }
        var destino = new File(acoes + "/" + ATN);
        if (!arquivoAtn.copy(destino)) { return null; }
        return destino;
    }

    // -----------------------------------------------------------------------
    var pasta = acharPasta();
    if (pasta === null) {
        alert("nao achei o " + ATN + ".\n\n" +
              "rode o instalador da biblioteca cura primeiro e depois abra este " +
              "script de novo.");
        return;
    }

    // idempotencia: tira quantos sets "cura" estiverem carregados antes de
    // carregar o novo. o teto de 20 e so pra nunca virar loop infinito se o
    // 'Dlt ' falhar calado.
    var voltas = 0;
    while (setExiste(SET) && voltas < 20) {
        try {
            removerSet(SET);
        } catch (e) {
            avisos.push("nao consegui tirar o conjunto \u0022cura\u0022 antigo do painel " +
                        "A\u00e7\u00f5es. pode ter ficado repetido — apague o de cima na m\u00e3o.");
            break;
        }
        voltas++;
    }

    try {
        app.load(new File(pasta + "/" + ATN));
    } catch (e) {
        alert("nao consegui carregar o atalho no Photoshop.\n\n" + e + "\n\n" +
              "tente de novo com o Photoshop rec\u00e9m-aberto, sem nenhuma " +
              "caixa de di\u00e1logo na tela.");
        return;
    }

    // o .jsx e o que o F2 vai abrir. sem ele o atalho existe mas so avisa que
    // o arquivo sumiu — melhor o aluno saber disso agora.
    if (!new File(pasta + "/" + JSX).exists) {
        avisos.push("o arquivo " + JSX + " nao esta em " + pasta + " — " +
                    "rode o instalador da biblioteca cura de novo.");
    }

    try {
        if (copiarPraPresets(new File(pasta + "/" + ATN)) === null) {
            // sem Presets da versao corrente (instalacao nao-padrao) ou copia
            // barrada: nao e problema, o set ja esta carregado.
            $.writeln("cura: copia pros Presets pulada");
        }
    } catch (e) {
        $.writeln("cura: copia pros Presets falhou: " + e);
    }

    var msg = "pronto. aperte F2 pra abrir o Cura Upscaler " +
              "(ou painel A\u00e7\u00f5es > cura).";
    if (avisos.length > 0) {
        msg = msg + "\n\n" + avisos.join("\n\n");
    }
    alert(msg);
})();
