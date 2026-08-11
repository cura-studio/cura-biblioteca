/**
 * Cura Upscaler
 *
 * Base script by Victor Reuther e Marcos Silveira
 * AI Model: philz1337x/clarity-upscaler on Replicate
 *
 * Rebranded for Cura Cursos with a minimal, monochrome interface.
 * The processing pipeline remains unchanged; only the product naming
 * and the ScriptUI presentation were adapted.
 */

#target photoshop

// ===== BRANDING =====
// Precisa vir ANTES de CONFIG: getAPIKey() pode abrir o dialogo de chave,
// que le BRAND.APP_NAME. Se BRAND ainda nao estiver atribuido, o dialogo
// quebra com "Erro 21: undefined nao e um objeto".
var BRAND = {
    APP_NAME: "Cura Upscaler",
    APP_VERSION: "2.91",
    HISTORY_LABEL: "Cura Upscaler",
    FOOTER_SIGNATURE: "Autor: João Tegoni - Curso Cura",
    LOGO_MARK: "{cura}",
    COLORS: {
        background: [0.04, 0.04, 0.04, 1],
        panel: [0.07, 0.07, 0.07, 1],
        text: [0.96, 0.96, 0.96, 1],
        muted: [0.72, 0.72, 0.72, 1],
        line: [0.30, 0.30, 0.30, 1],
        accent: [1, 1, 1, 1]
    }
};

// ===== CONFIGURATION =====
var CONFIG = {
    API_KEY: null,
    UPSCALER_MODEL_VERSION: "3bb9d3412f14261c2f8cfa15a56dd7b33f44af54777c517b860a3f678a5d7f3b",
    COST_PER_MEGAPIXEL: 0.004,
    MINIMUM_JOB_COST: 0.01,
    MAX_POLL_ATTEMPTS: 200,
    POLL_INTERVAL: 3,
    JPEG_QUALITY: 9,
    IS_WINDOWS: $.os.indexOf("Windows") !== -1
};
CONFIG.API_KEY = getAPIKey();

// ===== GLOBAL CANCEL FLAG =====
var PROCESS_CANCELLED = false;


// ===== HELPER FUNCTIONS =====
function hasActiveSelection() {
    try { var bounds = app.activeDocument.selection.bounds; return true; } 
    catch (e) { return false; }
}

function escapeForSuspendHistory(str) {
    if (typeof str !== 'string') return str;
    return str.replace(/\\/g, '\\\\')
              .replace(/'/g, "\\'")
              .replace(/\n/g, '\\n')
              .replace(/\r/g, '\\r');
}

function escapeJsonString(str) {
    return str.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n').replace(/\r/g, '\\r').replace(/\t/g, '\\t');
}

function openURL(url) {
    if (CONFIG.IS_WINDOWS) {
        app.system('cmd.exe /c start "" "' + url + '"');
    } else {
        app.system('open "' + url + '"');
    }
}

function applyBrandTheme(target) {
    var colors = BRAND.COLORS;
    var bgBrush = target.graphics.newBrush(target.graphics.BrushType.SOLID_COLOR, colors.background);
    var textPen = target.graphics.newPen(target.graphics.PenType.SOLID_COLOR, colors.text, 1);
    target.graphics.backgroundColor = bgBrush;
    target.graphics.foregroundColor = textPen;
    return {
        backgroundBrush: bgBrush,
        panelBrush: target.graphics.newBrush(target.graphics.BrushType.SOLID_COLOR, colors.panel),
        textPen: textPen,
        mutedPen: target.graphics.newPen(target.graphics.PenType.SOLID_COLOR, colors.muted, 1),
        linePen: target.graphics.newPen(target.graphics.PenType.SOLID_COLOR, colors.line, 1),
        accentPen: target.graphics.newPen(target.graphics.PenType.SOLID_COLOR, colors.accent, 1)
    };
}

function applyPanelTheme(panel, theme) {
    panel.graphics.backgroundColor = theme.panelBrush;
    panel.graphics.foregroundColor = theme.textPen;
    panel.graphics.pen = theme.linePen;
}

function getPromptPresets() {
    return {
        "Customizado": null,
        "Render Externo": {
            positive: "high-end exterior architectural render, epic realism, realistic facade materials, straight architectural lines, accurate windows, crisp landscaping, balanced natural lighting, clean sky, refined surface detail, sharp yet natural textures, premium visualization quality",
            negative: "cartoon, painting, illustration, warped perspective, bent lines, crooked edges, duplicate windows, melted buildings, broken geometry, deformed facade, bad proportions, noisy sky, oversaturated colors, dirt, grime, mud, stains, smudges, dust, debris, dirty walls, dirty floor, scratches, mold, damage, decay, noise, artifacts, blur, low quality, worst quality"
        },
        "Render Interno": {
            positive: "high-end interior architectural render, epic realism, realistic materials, clean furniture edges, accurate perspective, balanced ambient lighting, natural shadows, refined textures, elegant atmosphere, polished photoreal visualization, crisp details, premium finish",
            negative: "cartoon, painting, illustration, warped furniture, broken perspective, melted objects, duplicate decor, floating objects, misaligned furniture, noisy shadows, oversharpening, clutter artifacts, dirt, grime, mud, stains, smudges, dust, debris, dirty walls, dirty floor, scratches, mold, damage, decay, noise, artifacts, blur, low quality, worst quality"
        },
        "Figura Humana - Peles claras": {
            positive: "realistic human figure, epic realism, natural skin texture, proportionate anatomy, clean hair detail, believable clothing folds, authentic lighting, subtle depth, refined photographic realism, sharp and natural details, fair skin tones, light complexion, natural undertones, balanced highlights, realistic facial features, authentic skin detail without artificial smoothing",
            negative: "cartoon, painting, illustration, distorted anatomy, asymmetrical eyes, extra fingers, extra limbs, duplicated limbs, malformed hands, waxy skin, plastic texture, overprocessed skin, uncanny face, excessively dark skin, muddy skin tone, unnatural melanin shift, whitewashed skin, washed-out skin tone, dirt, grime, mud, stains, smudges, dust, debris, dirty skin, dirty clothes, scratches, damage, noise, artifacts, blur, low quality, worst quality"
        },
        "Figura Humana - Peles escuras": {
            positive: "realistic human figure, epic realism, natural skin texture, proportionate anatomy, clean hair detail, believable clothing folds, authentic lighting, subtle depth, refined photographic realism, sharp and natural details, dark skin tones, deep complexion, realistic melanin, rich natural undertones, balanced highlights, authentic skin detail without artificial smoothing",
            negative: "cartoon, painting, illustration, distorted anatomy, asymmetrical eyes, extra fingers, extra limbs, duplicated limbs, malformed hands, waxy skin, plastic texture, overprocessed skin, uncanny face, excessively pale skin, washed-out complexion, unnatural whitening, whitewashed skin, dirt, grime, mud, stains, smudges, dust, debris, dirty skin, dirty clothes, scratches, damage, noise, artifacts, blur, low quality, worst quality"
        },
        "Vegetação": {
            positive: "realistic vegetation, epic realism, natural foliage detail, crisp leaf definition, organic variation, believable atmosphere, realistic depth, healthy texture richness, balanced lighting, photoreal environmental detail, sharp and natural greenery",
            negative: "cartoon, painting, illustration, fake foliage, repeated leaves, repeated trees, pattern repetition, muddy textures, broken branches, dead plants, unnatural lighting, oversaturated greens, dirt, grime, mud, stains, smudges, dust, debris, dirty leaves, scratches, mold, damage, decay, noise, artifacts, blur, low quality, worst quality"
        }
    };
}

function applyPromptPreset(dialog, presetName) {
    var preset = dialog.promptPresets[presetName];
    if (!preset) {
        return;
    }
    dialog.modelDropdown.selection = 1;
    dialog.promptInput.text = preset.positive;
    dialog.negPromptInput.text = preset.negative;
    updateCostEstimateAndIndicators(dialog);
}

function setIndicatorState(indicator, isValid) {
    if (!indicator) {
        return;
    }
    var color = isValid ? [0.18, 0.78, 0.35, 1] : [0.85, 0.20, 0.20, 1];
    indicator.graphics.foregroundColor = indicator.graphics.newPen(indicator.graphics.PenType.SOLID_COLOR, color, 1);
}

function addValidationIndicator(group) {
    var indicator = group.add("statictext", undefined, "●");
    indicator.graphics.font = ScriptUI.newFont(indicator.graphics.font.name, ScriptUI.FontStyle.BOLD, 14);
    setIndicatorState(indicator, false);
    return indicator;
}

function isValueInRange(value, min, max, mustBeInteger) {
    if (mustBeInteger && value !== Math.round(value)) {
        return false;
    }
    if (isNaN(value)) {
        return false;
    }
    if (min !== null && value < min) {
        return false;
    }
    if (max !== null && value > max) {
        return false;
    }
    return true;
}

function updateParameterIndicators(dialog) {
    if (!dialog || !dialog.validationIndicators) {
        return;
    }

    setIndicatorState(dialog.validationIndicators.resValue, isValueInRange(parseFloat(dialog.resValueEditText.text), 1, null, true));
    setIndicatorState(dialog.validationIndicators.scale, isValueInRange(parseFloat(dialog.scaleEditText.text), 1, null, false));
    setIndicatorState(dialog.validationIndicators.resemblance, isValueInRange(parseFloat(dialog.resemblanceEditText.text), 0.3, 1.6, false));
    setIndicatorState(dialog.validationIndicators.creativity, isValueInRange(parseFloat(dialog.creativityEditText.text), 0.3, 0.9, false));
    setIndicatorState(dialog.validationIndicators.dynamic, isValueInRange(parseFloat(dialog.dynamicEditText.text), 3, 9, false));
    setIndicatorState(dialog.validationIndicators.steps, isValueInRange(parseFloat(dialog.stepsEditText.text), 1, null, true));
}

function updateCostEstimateAndIndicators(dialog) {
    if (dialog && dialog.refreshCostEstimate) {
        dialog.refreshCostEstimate();
    }
    updateParameterIndicators(dialog);
}

// ===== PROGRESS WINDOW =====
function createProgressWindow() {
    PROCESS_CANCELLED = false;
    var win = new Window("palette", BRAND.APP_NAME + " | Processando");
    win.orientation = "column";
    win.alignChildren = "fill";
    win.preferredSize.width = 380;
    win.margins = 15;
    win.spacing = 10;

    var theme = applyBrandTheme(win);

    var titleText = win.add("statictext", undefined, BRAND.LOGO_MARK);
    titleText.graphics.font = ScriptUI.newFont(titleText.graphics.font.name, ScriptUI.FontStyle.BOLD, 18);
    titleText.justify = "center";
    titleText.graphics.foregroundColor = theme.accentPen;

    var subtitleText = win.add("statictext", undefined, "Aprimorando imagem...");
    subtitleText.justify = "center";
    
    win.progressBar = win.add('progressbar', undefined, 0, 100);
    win.progressBar.preferredSize.height = 12;

    win.statusText = win.add("statictext", undefined, "Iniciando...");
    win.statusText.justify = "center";
    win.statusText.graphics.foregroundColor = theme.mutedPen;
    
    if (CONFIG.IS_WINDOWS) {
        win.add("panel");
        var warningText = win.add("statictext", undefined, "No Windows podem surgir janelas de comando rapidamente. Isso e normal.", { multiline: true });
        warningText.graphics.font = ScriptUI.newFont(warningText.graphics.font.name, ScriptUI.FontStyle.ITALIC, 9);
        warningText.justify = "center";
        warningText.graphics.foregroundColor = theme.mutedPen;
    }
    
    win.updateStatus = function(status, progressValue) { 
        try { 
            win.statusText.text = status; 
            if (progressValue !== undefined) {
                win.progressBar.value = progressValue;
            }
            win.update(); 
        } catch (e) {} 
    };

    win.show();
    return win;
}

// ===== CORE SCRIPT LOGIC =====
function checkCurlAvailable(){try{var testFile=new File(Folder.temp+"/curl_test_"+new Date().getTime()+".txt");var cmd;if(CONFIG.IS_WINDOWS){cmd='cmd.exe /c "curl.exe --version > "'+testFile.fsName+'" 2>&1"'}else{cmd='curl --version > "'+testFile.fsName+'" 2>&1'}
app.system(cmd);if(testFile.exists){testFile.open("r");var result=testFile.read();testFile.close();testFile.remove();return result.indexOf("curl")>-1}
return false}catch(e){return false}}
function showCurlMissingDialog(){var dialog=new Window("dialog",BRAND.APP_NAME+": curl nao encontrado");dialog.orientation="column";dialog.alignChildren="fill";dialog.preferredSize.width=450;
var theme=applyBrandTheme(dialog);
var message=dialog.add("statictext",undefined,"Este plugin precisa do 'curl' para funcionar.\n\n- No macOS e no Windows 10/11 ele costuma vir instalado.\n- Se falhar, confirme se o curl esta no PATH do sistema.",{multiline:true});message.preferredSize.height=100;message.graphics.foregroundColor=theme.textPen;
var okBtn=dialog.add("button",undefined,"OK");okBtn.onClick=function(){dialog.close()};dialog.show()}
function executeCurl(curlArgs,outputFile){var cmd;if(CONFIG.IS_WINDOWS){cmd='cmd.exe /c "curl.exe '+curlArgs+' > "'+outputFile+'" 2>&1"'}else{cmd='curl '+curlArgs+' > "'+outputFile+'" 2>&1'}
app.system(cmd);if(outputFile){var file=new File(outputFile);if(file.exists){file.open("r");var content=file.read();file.close();file.remove();return content}}
return null}
function encodeImageBase64(imageFile, progressWin){try{if(progressWin)progressWin.updateStatus("Encoding image...", 5);var outputFile=new File(Folder.temp+"/base64_"+new Date().getTime()+".txt");if(CONFIG.IS_WINDOWS){var fileName=imageFile.name||"";var ext="";var dotIndex=fileName.lastIndexOf(".");if(dotIndex>-1){ext=fileName.substring(dotIndex)}
if(!ext)ext=".jpg";var tempCopy=new File(Folder.temp+"/temp_encode_"+new Date().getTime()+ext);var copySuccess=false;try{copySuccess=imageFile.copy(tempCopy.fsName)}catch(e){copySuccess=false}
if(!copySuccess){app.system('cmd.exe /c copy /Y "'+imageFile.fsName+'" "'+tempCopy.fsName+'"')}
if(!tempCopy.exists){if(progressWin)progressWin.updateStatus("Error: Could not copy file", 5);return null}
var cmd='cmd.exe /c "certutil -encode "'+tempCopy.fsName+'" "'+outputFile.fsName+'""';app.system(cmd);tempCopy.remove();if(outputFile.exists){outputFile.open("r");var data=outputFile.read();outputFile.close();outputFile.remove();data=data.replace(/-----BEGIN CERTIFICATE-----/g,"").replace(/-----END CERTIFICATE-----/g,"").replace(/[\r\n\s]/g,"");return data}}else{var cmd='base64 -i "'+imageFile.fsName+'" > "'+outputFile.fsName+'"';app.system(cmd);if(outputFile.exists){outputFile.open("r");var data=outputFile.read();outputFile.close();outputFile.remove();return data.replace(/[\r\n\s]/g,"")}}}catch(e){if(progressWin)progressWin.updateStatus("Encoding error: "+e.message, 5)}
return null}
function extractPredictionId(response){try{var match=response.match(/"id"\s*:\s*"([^"]+)"/);if(match&&match[1]){return match[1]}}catch(e){}
return null}
function extractOutputUrl(response){try{var match=response.match(/"output"\s*:\s*\[?\s*"([^"]+)"/);if(match&&match[1]){return match[1]}}catch(e){}
return null}
function pollForResult(predictionId, progressWin){var maxAttempts=CONFIG.MAX_POLL_ATTEMPTS;for(var i=0;i<maxAttempts;i++){if(PROCESS_CANCELLED)return null;$.sleep(CONFIG.POLL_INTERVAL*1000);if(progressWin){var percent=Math.round(((i+1)/maxAttempts)*100);var progressBarValue=15+(percent*0.8);progressWin.updateStatus("AI is processing... "+percent+"%",progressBarValue)}
var statusFile=new File(Folder.temp+"/status_"+new Date().getTime()+".json");var curlArgs='-s -H "Authorization: Token '+CONFIG.API_KEY+'" -H "Content-Type: application/json" "https://api.replicate.com/v1/predictions/'+predictionId+'"';var response=executeCurl(curlArgs,statusFile.fsName);if(response&&!PROCESS_CANCELLED){if(response.indexOf('"status":"succeeded"')>-1){return downloadResult(response,progressWin)}else if(response.indexOf('"status":"failed"')>-1){alert("Generation failed");return null}}}
if(!PROCESS_CANCELLED){alert("Timeout - please try again")}
return null}
function downloadFile(url,destinationFile){try{var curlArgs='-s -L --insecure -o "'+destinationFile.fsName+'" "'+url+'"';var cmd;if(CONFIG.IS_WINDOWS){cmd='cmd.exe /c "curl.exe '+curlArgs+'"'}else{cmd='curl '+curlArgs}
app.system(cmd);return destinationFile.exists&&destinationFile.length>0}catch(e){return false}}
function downloadResult(response, progressWin){if(progressWin)progressWin.updateStatus("Downloading result...",95);var outputUrl=extractOutputUrl(response);if(!outputUrl){alert("Could not find output URL in API response.");return null}
var downloadedImageFile=new File(Folder.temp+"/clarity_result_"+new Date().getTime()+".png");if(downloadFile(outputUrl,downloadedImageFile)){if(progressWin)progressWin.updateStatus("Download complete!",100);return downloadedImageFile}else{alert("Failed to download the final image.");return null}}
function convertActiveLayerToSmartObject(){try{var idnewPlacedLayer=stringIDToTypeID("newPlacedLayer");executeAction(idnewPlacedLayer,undefined,DialogModes.NO)}catch(e){try{var idconvertToSmartObject=stringIDToTypeID("convertToSmartObject");executeAction(idconvertToSmartObject,undefined,DialogModes.NO)}catch(e){alert("Could not convert layer to Smart Object.")}}}
function placeResultInDocument(doc,resultFile,x1,y1,x2,y2,savedSelection){try{var resultDoc=app.open(resultFile);resultDoc.artLayers[0].duplicate(doc,ElementPlacement.PLACEATBEGINNING);resultDoc.close(SaveOptions.DONOTSAVECHANGES);convertActiveLayerToSmartObject();var newLayer=doc.activeLayer;newLayer.name="Objeto Inteligente com Upscale";var targetWidth=x2-x1;var targetHeight=y2-y1;newLayer.resize((targetWidth/newLayer.bounds[2].value)*100,(targetHeight/newLayer.bounds[3].value)*100,AnchorPosition.TOPLEFT);var finalBounds=newLayer.bounds;var dx=x1-finalBounds[0].value;var dy=y1-finalBounds[1].value;newLayer.translate(dx,dy);if(savedSelection){doc.selection.load(savedSelection);addLayerMask();doc.selection.deselect();savedSelection.remove()}else{addLayerMask();doc.selection.deselect()}}catch(e){alert("Placement error: "+e.message)}}
function selectAll(){app.activeDocument.selection.selectAll()}
function copyMerged(){var idCpyM=charIDToTypeID("CpyM");executeAction(idCpyM,undefined,DialogModes.NO)}
function addLayerMask(){try{var idMk=charIDToTypeID("Mk  ");var desc=new ActionDescriptor();var idNw=charIDToTypeID("Nw  ");var idChnl=charIDToTypeID("Chnl");desc.putClass(idNw,idChnl);var idAt=charIDToTypeID("At  ");var ref=new ActionReference();var idChnl=charIDToTypeID("Chnl");var idChnl=charIDToTypeID("Chnl");var idMsk=charIDToTypeID("Msk ");ref.putEnumerated(idChnl,idChnl,idMsk);desc.putReference(idAt,ref);var idUsng=charIDToTypeID("UsrM");var idUsrM=charIDToTypeID("UsrM");var idRvlS=charIDToTypeID("RvlS");desc.putEnumerated(idUsng,idUsrM,idRvlS);executeAction(idMk,desc,DialogModes.NO)}catch(e){}}

// ===== API KEY MANAGEMENT =====
function getAPIKey(){var apiKey=loadAPIKey();if(!apiKey||apiKey.length<10){apiKey=promptForAPIKey(false);if(apiKey&&apiKey.length>10){saveAPIKey(apiKey);CONFIG.API_KEY=apiKey}}
return apiKey}
function getPreferencesFile(){var prefsFolder=new Folder(Folder.userData+"/Ps_Clarity_Upscaler_V2");if(!prefsFolder.exists){prefsFolder.create()}
return new File(prefsFolder+"/preferences.json")}
function loadAPIKey(){try{var prefsFile=getPreferencesFile();if(prefsFile.exists){prefsFile.open("r");var content=prefsFile.read();prefsFile.close();var match=content.match(/"apiKey"\s*:\s*"([^"]+)"/);if(match&&match[1]){return match[1]}}}catch(e){}
return null}
function saveAPIKey(apiKey){try{var prefsFile=getPreferencesFile();prefsFile.open("w");prefsFile.write('{"apiKey":"'+apiKey+'"}');prefsFile.close();return true}catch(e){return false}}
function promptForAPIKey(fromSettings){var dialog=new Window("dialog",BRAND.APP_NAME+" | Chave da API");dialog.orientation="column";dialog.alignChildren="fill";dialog.preferredSize.width=450;dialog.margins=15;dialog.spacing=10;
var theme=applyBrandTheme(dialog);
var apiKeyPanel=dialog.add("panel",undefined,"Replicate API Key");apiKeyPanel.alignChildren="left";apiKeyPanel.margins=10;applyPanelTheme(apiKeyPanel,theme);
var apiKeyGroup=apiKeyPanel.add("group");apiKeyGroup.add("statictext",undefined,"Chave:");var apiKeyInput=apiKeyGroup.add("edittext",undefined,"");apiKeyInput.characters=40;apiKeyInput.preferredSize.width=300;
if(fromSettings&&CONFIG.API_KEY){apiKeyInput.text=CONFIG.API_KEY;apiKeyInput.active=true;var maskedKey=CONFIG.API_KEY.substr(0,8)+"..."+CONFIG.API_KEY.substr(-4);var currentKeyText=apiKeyPanel.add("statictext",undefined,"Chave atual: "+maskedKey);currentKeyText.graphics.font=ScriptUI.newFont(currentKeyText.graphics.font.name,ScriptUI.FontStyle.ITALIC,10);currentKeyText.graphics.foregroundColor=theme.mutedPen}else{apiKeyInput.active=true}
var privacyText=apiKeyPanel.add("statictext",undefined,"(A chave fica salva localmente neste computador.)");privacyText.graphics.font=ScriptUI.newFont(privacyText.graphics.font.name,ScriptUI.FontStyle.ITALIC,10);privacyText.graphics.foregroundColor=theme.mutedPen;
var buttonGroup=dialog.add("group");buttonGroup.alignment="center";buttonGroup.spacing=15;
var creditsButton=buttonGroup.add("button",undefined,"Faturamento");creditsButton.helpTip="Abrir a pagina de cobranca do Replicate";creditsButton.onClick=function(){openURL("https://replicate.com/account/billing")};var dashboardButton=buttonGroup.add("button",undefined,"Painel");dashboardButton.helpTip="Abrir o painel do Replicate";dashboardButton.onClick=function(){openURL("https://replicate.com")};
var okButton=buttonGroup.add("button",undefined,fromSettings?"Salvar chave":"Confirmar");var cancelButton=buttonGroup.add("button",undefined,"Cancelar");
okButton.onClick=function(){if(apiKeyInput.text.length<10){alert("Informe uma API key valida.")}else{dialog.close(1)}};cancelButton.onClick=function(){dialog.close(0)};var result=dialog.show();if(result==1){return apiKeyInput.text}
return null}

// ===== MAIN DIALOG =====
function createDialog(initialWidth, initialHeight) {
    var dialog = new Window("dialog", BRAND.APP_NAME + " " + BRAND.APP_VERSION);
    dialog.orientation = "column";
    dialog.alignChildren = "fill";
    dialog.spacing = 10;
    dialog.margins = 10;
    
    var theme = applyBrandTheme(dialog);

    var headerGroup = dialog.add("group");
    headerGroup.alignment = "fill";
    var titleText = headerGroup.add("statictext", undefined, BRAND.LOGO_MARK);
    titleText.graphics.font = ScriptUI.newFont(titleText.graphics.font.name, ScriptUI.FontStyle.BOLD, 20);
    titleText.graphics.foregroundColor = theme.accentPen;

    var headerSpacer = headerGroup.add("group");
    headerSpacer.alignment = "fill";

    var courseLink = headerGroup.add("button", undefined, "curso de inteligência artificial");
    courseLink.alignment = "right";
    courseLink.preferredSize.height = 22;
    courseLink.helpTip = "Abrir pagina do curso";
    courseLink.onClick = function() {
        openURL("https://cursocura.com.br/nossos-cursos/721/ia");
    };

    var authorGroup = dialog.add("group");
    authorGroup.alignment = "fill";
    var authorText = authorGroup.add("statictext", undefined, BRAND.FOOTER_SIGNATURE);
    authorText.graphics.font = ScriptUI.newFont(authorText.graphics.font.name, ScriptUI.FontStyle.REGULAR, 10);
    authorText.graphics.foregroundColor = theme.mutedPen;

    var subheaderGroup = dialog.add("group");
    subheaderGroup.alignment = "fill";
    var introText = subheaderGroup.add("statictext", undefined, "Script de upscale utilizando o modelo epicrealism_naturalSinRC1VAE, desenvolvido pela equipe do cura");
    introText.graphics.foregroundColor = theme.mutedPen;
    introText.preferredSize.width = 560;

    var presetPanel = dialog.add("panel", undefined, "Preset de imagem");
    presetPanel.alignChildren = "fill";
    applyPanelTheme(presetPanel, theme);
    var presetGroup = presetPanel.add("group");
    presetGroup.add("statictext", undefined, "Tipo:");
    dialog.promptPresets = getPromptPresets();
    var presetItems = [];
    for (var presetName in dialog.promptPresets) {
        if (dialog.promptPresets.hasOwnProperty(presetName)) {
            presetItems.push(presetName);
        }
    }
    dialog.presetDropdown = presetGroup.add("dropdownlist", undefined, presetItems);
    dialog.presetDropdown.selection = 0;
    dialog.presetDropdown.preferredSize.width = 180;
    dialog.presetDropdown.helpTip = "Seleciona um tipo de imagem e preenche prompts padrao em ingles.";

    var resControlGroup = dialog.add("panel", undefined, "Resolucao de preparo");
    resControlGroup.alignChildren = "left";
    applyPanelTheme(resControlGroup, theme);
    var radioGroup = resControlGroup.add("group");
    radioGroup.orientation = "row";
    dialog.maxResRadio = radioGroup.add("radiobutton", undefined, "Limitar maximo");
    dialog.minResRadio = radioGroup.add("radiobutton", undefined, "Garantir minimo");
    dialog.maxResRadio.value = true;
    dialog.maxResRadio.helpTip = "Se a selecao for maior que esse valor, ela sera reduzida antes do envio.";
    dialog.minResRadio.helpTip = "Se a selecao for menor que esse valor, ela sera ampliada antes do envio.";
    var resValueGroup = resControlGroup.add("group");
    resValueGroup.add("statictext", undefined, "Valor (lado maior em px):");
    dialog.resValueEditText = resValueGroup.add("edittext", undefined, "2500");
    dialog.resValueEditText.preferredSize.width = 80;
    dialog.validationIndicators = {};
    dialog.validationIndicators.resValue = addValidationIndicator(resValueGroup);

    var mainControls = dialog.add("panel", undefined, "Controles avancados");
    mainControls.alignChildren = "left";
    applyPanelTheme(mainControls, theme);
    var scaleGroup = mainControls.add("group");
    scaleGroup.add("statictext", undefined, "Fator de upscale:").preferredSize.width = 120;
    dialog.scaleEditText = scaleGroup.add("edittext", undefined, "2");
    dialog.scaleEditText.preferredSize.width = 80;
    dialog.scaleEditText.helpTip = "Fator de ampliacao da imagem. Ex.: 2 dobra o tamanho.";
    dialog.validationIndicators.scale = addValidationIndicator(scaleGroup);
    var resemblanceGroup = mainControls.add("group");
    resemblanceGroup.add("statictext", undefined, "Fidelidade:").preferredSize.width = 120;
    dialog.resemblanceEditText = resemblanceGroup.add("edittext", undefined, "0.9");
    dialog.resemblanceEditText.preferredSize.width = 80;
    dialog.resemblanceEditText.helpTip = "Define o quanto o resultado deve permanecer fiel a imagem original (0.3 a 1.6).";
    dialog.validationIndicators.resemblance = addValidationIndicator(resemblanceGroup);
    var creativityGroup = mainControls.add("group");
    creativityGroup.add("statictext", undefined, "Criatividade:").preferredSize.width = 120;
    dialog.creativityEditText = creativityGroup.add("edittext", undefined, "0.33");
    dialog.creativityEditText.preferredSize.width = 80;
    dialog.creativityEditText.helpTip = "Controla a intensidade dos refinamentos e dos detalhes gerados (0.3 a 0.9).";
    dialog.validationIndicators.creativity = addValidationIndicator(creativityGroup);
    var dynamicGroup = mainControls.add("group");
    dynamicGroup.add("statictext", undefined, "Dinamica (HDR):").preferredSize.width = 120;
    dialog.dynamicEditText = dynamicGroup.add("edittext", undefined, "6");
    dialog.dynamicEditText.preferredSize.width = 80;
    dialog.dynamicEditText.helpTip = "Controla o High Dynamic Range. Valores maiores podem aumentar o contraste (3-9).";
    dialog.validationIndicators.dynamic = addValidationIndicator(dynamicGroup);
    var stepsGroup = mainControls.add("group");
    stepsGroup.add("statictext", undefined, "Passos:").preferredSize.width = 120;
    dialog.stepsEditText = stepsGroup.add("edittext", undefined, "30");
    dialog.stepsEditText.preferredSize.width = 80;
    dialog.stepsEditText.helpTip = "Quantidade de passos de refinamento. Mais passos podem melhorar detalhes, mas levam mais tempo.";
    dialog.validationIndicators.steps = addValidationIndicator(stepsGroup);
    var modelGroup = mainControls.add("group");
    modelGroup.add("statictext", undefined, "Modo:").preferredSize.width = 120;
    
    dialog.modelMap = {
        "Refiner": "juggernaut_reborn.safetensors [338b85bc4f]",
        "Realistic": "epicrealism_naturalSinRC1VAE.safetensors [84d76a0328]"
    };
    var displayItems = ["Refiner", "Realistic"];
    
    dialog.modelDropdown = modelGroup.add("dropdownlist", undefined, displayItems);
    dialog.modelDropdown.selection = 1; // Default "Realistic"
    dialog.modelDropdown.preferredSize.width = 180;
    dialog.modelDropdown.helpTip = "Escolhe o modelo base de Stable Diffusion, o que influencia bastante o estilo do resultado.";
    
    var promptGroup = dialog.add("panel", undefined, "Prompts opcionais");
    promptGroup.alignChildren = "fill";
    applyPanelTheme(promptGroup, theme);
    promptGroup.add("statictext", undefined, "Prompt positivo:");
    dialog.promptInput = promptGroup.add("edittext", undefined, "masterpiece, best quality, highres, <lora:more_details:0.5> <lora:SDXLrender_v2.0:1>", {multiline: true});
    dialog.promptInput.preferredSize.height = 58;
    promptGroup.add("statictext", undefined, "Prompt negativo:");
    var defaultNegativePrompt = "(worst quality, low quality, normal quality:2) JuggernautNegative-neg";
    var realisticNegativePrompt = "cartoon, painting, illustration, (worst quality, low quality, normal quality:2)";
    dialog.negPromptInput = promptGroup.add("edittext", undefined, realisticNegativePrompt, {multiline: true}); // Default for Realistic
    dialog.negPromptInput.preferredSize.height = 58;

    dialog.modelDropdown.onChange = function() {
        var selectedModelText = this.selection.text;
        if (selectedModelText === "Realistic") {
            dialog.negPromptInput.text = realisticNegativePrompt;
        } else {
            dialog.negPromptInput.text = defaultNegativePrompt;
        }
    };
    dialog.presetDropdown.onChange = function() {
        applyPromptPreset(dialog, this.selection.text);
    };
    
    var footerGroup = dialog.add("group");
    footerGroup.alignment = "fill";
    var settingsBtn = footerGroup.add("button", undefined, "API");
    settingsBtn.helpTip = "Configurar a chave da API";
    settingsBtn.preferredSize.width = 30;
    settingsBtn.onClick = function() {
        var newKey = promptForAPIKey(true);
        if (newKey && newKey.length > 10) {
            if (saveAPIKey(newKey)) { CONFIG.API_KEY = newKey; alert("API key atualizada com sucesso."); } 
            else { alert("Nao foi possivel salvar a API key."); }
        }
    };
    
    var costGroup = footerGroup.add("group");
    costGroup.alignment = "left";
    dialog.costText = costGroup.add("statictext", undefined, "Custo estimado: ~$0.00");
    dialog.costText.graphics.foregroundColor = theme.mutedPen;

    var buttonGroup = footerGroup.add("group");
    buttonGroup.alignment = "right";
    var enhanceButton = buttonGroup.add("button", undefined, "Aplicar");
    var cancelButton = buttonGroup.add("button", undefined, "Cancelar");
    dialog.defaultElement = enhanceButton;
    enhanceButton.onClick = function() { dialog.close(1); };
    cancelButton.onClick = function() { dialog.close(0); };

    function updateCostEstimate() {
        try {
            var width = initialWidth;
            var height = initialHeight;
            var resValue = parseInt(dialog.resValueEditText.text, 10);
            var scaleFactor = parseFloat(dialog.scaleEditText.text);
            var resMode = dialog.maxResRadio.value ? "max" : "min";
            if (isNaN(resValue) || isNaN(scaleFactor)) { dialog.costText.text = "Entrada invalida"; return; }
            var largestSide = Math.max(width, height);
            var preProcessWidth = width;
            var preProcessHeight = height;
            var shouldResize = false;
            if (resMode === "max" && largestSide > resValue) { shouldResize = true; } 
            else if (resMode === "min" && largestSide < resValue) { shouldResize = true; }
            if (shouldResize) {
                var scale = resValue / largestSide;
                preProcessWidth = Math.round(width * scale);
                preProcessHeight = Math.round(height * scale);
            }
            var finalWidth = preProcessWidth * scaleFactor;
            var finalHeight = preProcessHeight * scaleFactor;
            var megapixels = (finalWidth * finalHeight) / 1000000;
            var estimatedCost = megapixels * CONFIG.COST_PER_MEGAPIXEL;
            
            var displayCost = Math.max(estimatedCost, CONFIG.MINIMUM_JOB_COST);
            
            dialog.costText.text = "Custo estimado: ~$" + displayCost.toFixed(2);

        } catch (e) {
            dialog.costText.text = "Custo estimado: N/A";
        }
    }
    dialog.refreshCostEstimate = updateCostEstimate;

    dialog.resValueEditText.onChanging = function() {
        updateCostEstimateAndIndicators(dialog);
    };
    dialog.scaleEditText.onChanging = function() {
        updateCostEstimateAndIndicators(dialog);
    };
    dialog.resemblanceEditText.onChanging = function() {
        updateParameterIndicators(dialog);
    };
    dialog.creativityEditText.onChanging = function() {
        updateCostEstimateAndIndicators(dialog);
    };
    dialog.dynamicEditText.onChanging = function() {
        updateParameterIndicators(dialog);
    };
    dialog.stepsEditText.onChanging = function() {
        updateParameterIndicators(dialog);
    };
    dialog.maxResRadio.onClick = function() {
        updateCostEstimateAndIndicators(dialog);
    };
    dialog.minResRadio.onClick = function() {
        updateCostEstimateAndIndicators(dialog);
    };
    dialog.onShow = function() {
        updateCostEstimateAndIndicators(dialog);
    };

    return dialog;
}

// ===== API CALL FOR UPSCALER =====
function callUpscalerAPI(imageFile, params, progressWin) {
    try {
        if (PROCESS_CANCELLED) return null;
        var base64Data = encodeImageBase64(imageFile, progressWin);
        if (!base64Data || PROCESS_CANCELLED) { if (!PROCESS_CANCELLED) alert("Nao foi possivel codificar a imagem."); return null; }
        var mainImageUrl = "data:image/jpeg;base64," + base64Data;
        if (progressWin) progressWin.updateStatus("Preparando requisicao...", 10);
        
        var payload = '{"version":"' + CONFIG.UPSCALER_MODEL_VERSION + '", "input":{';
        payload += '"image":"' + mainImageUrl + '",';
        payload += '"prompt":"' + escapeJsonString(params.prompt) + '",';
        payload += '"negative_prompt":"' + escapeJsonString(params.negPrompt) + '",';
        payload += '"scale_factor":' + params.scaleFactor + ',';
        payload += '"creativity":' + params.creativity + ',';
        payload += '"resemblance":' + params.resemblance + ',';
        payload += '"dynamic":' + params.dynamic + ',';
        payload += '"num_inference_steps":' + params.steps + ',';
        payload += '"sd_model":"' + escapeJsonString(params.model) + '"';
        payload += '}}';

        var payloadFile = new File(Folder.temp + "/upscaler_payload_" + new Date().getTime() + ".json");
        payloadFile.open("w");
        payloadFile.write(payload);
        payloadFile.close();
        if (PROCESS_CANCELLED) { payloadFile.remove(); return null; }
        if (progressWin) progressWin.updateStatus("Enviando para o modelo...", 15);
        var responseFile = new File(Folder.temp + "/upscaler_response_" + new Date().getTime() + ".json");
        var curlArgs = '-s -X POST -H "Authorization: Token ' + CONFIG.API_KEY + '" -H "Content-Type: application/json" -H "Prefer: wait" -d @"' + payloadFile.fsName + '" "https://api.replicate.com/v1/predictions"';
        var response = executeCurl(curlArgs, responseFile.fsName);
        payloadFile.remove();
        if (!response || PROCESS_CANCELLED) { if (!PROCESS_CANCELLED) alert("Sem resposta da API."); return null; }
        
        if (/^\s*\{\s*"detail"\s*:.+/.test(response)) {
            alert("Erro de API. Confira sua chave nas configuracoes.\n\nResposta do servidor:\n" + response.substring(0, 200));
            return null;
        }
        
        if (response.indexOf('"status":"succeeded"') > -1 && response.indexOf('"output"') > -1) {
            return downloadResult(response, progressWin);
        }
        var predictionId = extractPredictionId(response);
        if (predictionId) { return pollForResult(predictionId, progressWin); }
        alert("Resposta inesperada da API: " + response.substring(0, 200));
        return null;
    } catch(e) {
        if (!PROCESS_CANCELLED) alert("Erro de API: " + e.message);
        return null;
    }
}

// ===== PROCESSING & MAIN FUNCTIONS =====
function processSelection(params) {
    try {
        var doc = app.activeDocument;
        var savedSelection = null;
        if (hasActiveSelection() && params.originalSelectionExists) {
            savedSelection = doc.channels.add();
            savedSelection.name = "Upscaler Selection";
            doc.selection.store(savedSelection);
        }
        var bounds = doc.selection.bounds;
        var x1 = Math.round(bounds[0].value);
        var y1 = Math.round(bounds[1].value);
        var x2 = Math.round(bounds[2].value);
        var y2 = Math.round(bounds[3].value);
        var tempFile = exportSelection(doc, x1, y1, x2, y2, params.resMode, params.resValue);
        if (!tempFile || !tempFile.exists) { alert("Nao foi possivel exportar a selecao."); if(savedSelection) savedSelection.remove(); return; }
        var progressWin = createProgressWindow();
        var resultFile = callUpscalerAPI(tempFile, params, progressWin);
        tempFile.remove();
        if (PROCESS_CANCELLED) { if (progressWin) progressWin.close(); if(savedSelection) savedSelection.remove(); return; }
        if (resultFile && resultFile.exists) {
            if (progressWin) progressWin.updateStatus("Posicionando resultado...", 100);
            placeResultInDocument(doc, resultFile, x1, y1, x2, y2, savedSelection);
            resultFile.remove();
        } else {
            if (!PROCESS_CANCELLED) { alert("Nao foi possivel finalizar o upscale."); }
            if(savedSelection) savedSelection.remove();
        }
        if(progressWin) progressWin.close();
    } catch(e) {
        alert("Erro de processamento: " + e.message);
    }
}
function exportSelection(doc, x1, y1, x2, y2, resMode, resValue) {
    try {
        doc.selection.deselect();
        doc.artLayers.add();
        var tempLayer = doc.activeLayer;
        tempLayer.name = "Temp Merged";
        selectAll();
        copyMerged();
        doc.paste();
        var cropDoc = doc.duplicate("temp_crop", true);
        cropDoc.crop([x1, y1, x2, y2]);
        var width = cropDoc.width.value;
        var height = cropDoc.height.value;
        var largestSide = Math.max(width, height);
        var shouldResize = false;
        if (resMode === "max" && largestSide > resValue) { shouldResize = true; } 
        else if (resMode === "min" && largestSide < resValue) { shouldResize = true; }
        if (shouldResize) {
            var scale = resValue / largestSide;
            var newWidth = Math.round(width * scale);
            var newHeight = Math.round(height * scale);
            cropDoc.resizeImage(UnitValue(newWidth, "px"), UnitValue(newHeight, "px"), null, ResampleMethod.BICUBIC);
        }
        var timestamp = new Date().getTime();
        var tempFile = new File(Folder.temp + "/ai_input_" + timestamp + ".jpg");
        var saveOptions = new JPEGSaveOptions();
        saveOptions.quality = CONFIG.JPEG_QUALITY;
        cropDoc.saveAs(tempFile, saveOptions, true, Extension.LOWERCASE);
        cropDoc.close(SaveOptions.DONOTSAVECHANGES);
        doc.activeLayer = tempLayer;
        tempLayer.remove();
        return tempFile;
    } catch (e) { alert("Erro ao exportar: " + e.message); return null; }
}

function main() {
    if (!checkCurlAvailable()) { showCurlMissingDialog(); return; }
    if (!getAPIKey()) { return; }
    if (!app.documents.length) { alert("Abra uma imagem no Photoshop antes de executar o plugin."); return; }
    
    var params = {};
    params.originalSelectionExists = hasActiveSelection();
    
    if (!params.originalSelectionExists) {
        app.activeDocument.selection.selectAll();
    }
    
    var initialWidth, initialHeight;
    try {
        var bounds = app.activeDocument.selection.bounds;
        initialWidth = bounds[2].value - bounds[0].value;
        initialHeight = bounds[3].value - bounds[1].value;
    } catch (e) {
        alert("Nao foi possivel obter as dimensoes da selecao. Tente novamente.");
        if (!params.originalSelectionExists) { app.activeDocument.selection.deselect(); }
        return;
    }
    
    var dialog = createDialog(initialWidth, initialHeight);
    var result = dialog.show();

    if (result == 1) {
        params.scaleFactor = parseFloat(dialog.scaleEditText.text);
        params.creativity = parseFloat(dialog.creativityEditText.text);
        params.resemblance = parseFloat(dialog.resemblanceEditText.text);
        params.dynamic = parseFloat(dialog.dynamicEditText.text);
        params.steps = parseInt(dialog.stepsEditText.text);
        params.resValue = parseInt(dialog.resValueEditText.text);
        params.resMode = dialog.maxResRadio.value ? "max" : "min";
        
        var selectedDisplayName = dialog.modelDropdown.selection.text;
        params.model = dialog.modelMap[selectedDisplayName];
        
        if (isNaN(params.scaleFactor) || isNaN(params.creativity) || isNaN(params.resemblance) || isNaN(params.dynamic) || isNaN(params.steps) || isNaN(params.resValue)) {
            alert("Preencha todos os campos numericos com valores validos.");
            if (!params.originalSelectionExists) { app.activeDocument.selection.deselect(); }
            return;
        }
        
        params.prompt = dialog.promptInput.text;
        params.negPrompt = dialog.negPromptInput.text;

        var paramsString = "{";
        for (var key in params) {
            if (typeof params[key] == 'string') {
                paramsString += key + ":'" + escapeForSuspendHistory(params[key]) + "',";
            } else {
                paramsString += key + ":" + params[key] + ",";
            }
        }
        paramsString = paramsString.slice(0, -1) + "}";
        
        app.activeDocument.suspendHistory(BRAND.HISTORY_LABEL, "processSelection(" + paramsString + ")");

    } else {
        if (!params.originalSelectionExists) {
            app.activeDocument.selection.deselect();
        }
    }
}

main();
