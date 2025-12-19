clear; clc; close all; % ortamı temizliyorum. Eski kalmış değişkenleri sildim.

CFG = struct(); % Tüm parametreleri tek structta topluyorum.

CFG.DATA_FILE = "Concrete_Data.xls";   % Data file yolunu düzenleyin.

CFG.SHEET_NAME = "";  % birden fazla sheet(sayfa) varsa yanlış tablo okunursa buraya istediğim tabloyu yazarım.

CFG.RNG_SEED = 42; % Train val test için rastgele ayarlama için

CFG.SPLIT_TRAIN = 0.70; % train verisi tüm verinin %70'i
CFG.SPLIT_VAL   = 0.15; % Validation %15
CFG.SPLIT_TEST  = 0.15; % Test %15

% ANFIS training
CFG.EPOCHS  = 120;         
CFG.MF_TYPE = "gaussmf";     % Üyelik Fonksiyonu
CFG.MF_COUNT = 2;            % MF, Her değer için kaç tane üyelik fonksiyonunun kümesi olacağını söylüyor. High/Low gibi.
% Burayı 2 verdim ki patlama olmasın. Yani sayı artarsa kural sayısı artar!
% karmaşıklık artar. Bu proje için 2 ideal.

% Strategy for inputs:
%   'A' -> 4-5 girdi seç (kural patlamasını önler)
%   'B' -> Her birinde 2 üyelik fonksiyonu(MF) bulunan 8 girdinin tamamını kullanır (kurallar = 2^8 = 256)
CFG.STRATEGY = 'A';
CFG.NUM_INPUTS_A = 5;        % 4 or 5

% Script normalde sütun isimlerinden otomatik X/Y bulmaya çalışır (özellikle Y için "strength/compressive" gibi).
% Bulamazsa burada elle belirteceğim.
CFG.X_COLS = [];             % Değer sütunları: ["Cement","Water","Age","Superplasticizer","Blast_Furnace_Slag"]
CFG.Y_COL  = "";             % Çıktı: "Concrete_compressive_strength"

% seçtiğin Y sütununun (hedef değişkenin) min–max aralığı 0 ile 150
% arasında mı diye kontrol ediyor. Değilse hata verir.
CFG.Y_RANGE_MPA = [0 150];

% çıktılar
CFG.OUT_DIR   = pwd; % Bulunduğum dizine kaydeder.
CFG.MODEL_MAT = fullfile(CFG.OUT_DIR, "anfis_concrete_model.mat"); % .mat: MATLAB değişkenleri (FIS + scaler + metadata) birlikte saklanır.
CFG.MODEL_FIS = fullfile(CFG.OUT_DIR, "anfis_concrete_model.fis"); % .fis: FIS dosyası; readfis/writeFIS ile taşınabilir.

% Eğitim bittikten sonra chkError eğrisine bakıyor.
CFG.OVERFIT_REL_INCREASE = 0.05;  % son epoch, en iyi epoch'a göre %5'ten fazla kötüleşti mi diye log kaydı alıyor eğer kötüleştiyse overfitting sinyali diye geçiyor.
%% ========================== CONFIG BİTTİ =====================================


%% 1) Toolbox / function var mı diye kontrol hücresi
requiredFns = ["anfis","anfisOptions","evalfis"]; % ANFIS eğitim zincirini çalıştırmak için gerekli 3 fonksiyon.
missing = requiredFns(arrayfun(@(f) exist(f,'file') ~= 2, requiredFns)); % missing: eksik bulunan fonksiyon isimlerini içeren dizi.

% Initial FIS generator: prefer genfis1 (grid partition), else fallback to genfis
hasGenfis1 = (exist("genfis1",'file') == 2);
hasGenfis  = (exist("genfis",'file') == 2);

if ~isempty(missing) % True ise kayıp fonksiyon var demek ki ve mesaj veriyor 
    fprintf(2, "ERROR: Missing required functions: %s\n", strjoin(cellstr(missing), ", "));
    fprintf(2, "You need to install/enable: Fuzzy Logic Toolbox.\n");
    fprintf(2, "MATLAB Add-On Explorer -> search 'Fuzzy Logic Toolbox'.\n");
    error("ToolboxMissing");
end
if ~hasGenfis1 && ~hasGenfis 
    fprintf(2, "ERROR: Neither genfis1 nor genfis found. Cannot generate initial FIS.\n");
    fprintf(2, "Install/enable Fuzzy Logic Toolbox (or update MATLAB).\n");
    error("ToolboxMissingGenFIS");
end

%% 1) Read data (xls/csv supported via readtable)
if ~isfile(CFG.DATA_FILE)
    error("Data file not found: %s (Fix CFG.DATA_FILE)", CFG.DATA_FILE);
end

fprintf("Reading data from: %s\n", CFG.DATA_FILE);

try
    if strlength(CFG.SHEET_NAME) > 0
        T = readtable(CFG.DATA_FILE, 'Sheet', CFG.SHEET_NAME);
    else
        T = readtable(CFG.DATA_FILE);
    end
catch ME
    fprintf(2, "ERROR reading file with readtable(): %s\n", ME.message);
    fprintf(2, "If Excel reading fails, try exporting the file to CSV and set CFG.DATA_FILE accordingly.\n");
    rethrow(ME);
end

fprintf("\n---- Detected variable names (T.Properties.VariableNames) ----\n");
disp(T.Properties.VariableNames');

%% 2) tabloda hangi sütunların X (inputs) ve Y (target) olacağını güvenli şekilde seçiyor.
varNames = T.Properties.VariableNames; % tablodaki sütun isimlerini getiriyorum.
namesAreMeaningful = ~all(startsWith(string(varNames), "Var", "IgnoreCase", true)); % Bu isimler anlamlı mı diye bakıyor.

% Resolve Y
if ~isEmptySelection(CFG.Y_COL)
    [YName, YIdx] = resolveColumnByUserSelection(T, CFG.Y_COL, "Y_COL");
elseif namesAreMeaningful
    % Auto-detect target: prefer 'strength' and/or 'compressive'
    YIdx = pickVarByKeywords(varNames, ["strength","compressive"], "Target/Strength");
    if isempty(YIdx)
        error("Auto-detect failed for Y. Set CFG.Y_COL (name or index).");
    end
    YName = varNames{YIdx};
else
    error("Table appears to have no meaningful headers. Set CFG.Y_COL and CFG.X_COLS as numeric indices in CONFIG.");
end

% X sütunları için
if ~isEmptySelection(CFG.X_COLS)
    [XNames, XIdx] = resolveMultipleColumnsByUserSelection(T, CFG.X_COLS, "X_COLS");
elseif namesAreMeaningful
    switch upper(string(CFG.STRATEGY))
        case "A"
            XIdx = autoSelectInputsStrategyA(varNames, YIdx, CFG.NUM_INPUTS_A);
            XNames = varNames(XIdx);

            if numel(XIdx) < 4
                error("Strategy A failed to select >=4 inputs. Set CFG.X_COLS explicitly.");
            end

            fprintf("\n[Strategy A] Selected %d inputs to control rule explosion.\n", numel(XIdx));
            fprintf("Rule count approx = %d^%d = %d rules (grid partition).\n", ...
                CFG.MF_COUNT, numel(XIdx), CFG.MF_COUNT^numel(XIdx));

        case "B"
            XIdx = setdiff(1:width(T), YIdx, 'stable');
            XNames = varNames(XIdx);

            fprintf("\n[Strategy B] Using ALL %d input columns (excluding target).\n", numel(XIdx));
            fprintf("With %d MFs/input => rule count approx = %d^%d = %d rules.\n", ...
                CFG.MF_COUNT, CFG.MF_COUNT, numel(XIdx), CFG.MF_COUNT^numel(XIdx));
            fprintf("This is usually heavier and more overfit-prone than Strategy A.\n");

            % Optional sanity: dataset expected 8 inputs
            if numel(XIdx) ~= 8
                fprintf(2, "WARNING: Expected 8 inputs for UCI concrete, but found %d (excluding target).\n", numel(XIdx));
            end

        otherwise
            error("CFG.STRATEGY must be 'A' or 'B'.");
    end
else
    error("Table appears to have no meaningful headers. Set CFG.X_COLS as numeric indices in CONFIG.");
end

% Seçimleri yazdır.
fprintf("\n---- Sütun seçimleri ----\n");
fprintf("Y (target)  : %s\n", string(YName));
fprintf("X (inputs)  : %s\n", strjoin(string(XNames), ", "));

% Enforce: X does not include Y
if any(XIdx == YIdx)
    error("Yapılandırma hatası: X sütunu Y sütununu içeriyor. CFG.X_COLS / CFG.Y_COL değerlerini düzeltin.");
end

%% 3) Ayıklama, temizleme
try
    if namesAreMeaningful
        X = T{:, XNames};
        Y = T{:, YName};
    else
        X = T{:, XIdx};
        Y = T{:, YIdx};
    end
catch ME
    fprintf(2, "Tablodan X/Y değerlerini çıkarırken HATA oluştu: %s\n", ME.message);
    error("X/Y değerleri çıkarılamadı. Başlıklar tek sayı ise, CFG.X_COLS/CFG.Y_COL değerlerini ayarlayın.");
end

X = double(X);
Y = double(Y(:));

% NaN/Inf gibi boş satırları siliyorm
bad = any(~isfinite(X), 2) | ~isfinite(Y);
if any(bad)
    fprintf(2, "UYARI: NaN/Inf değerine sahip %d satır siliniyor.\n", sum(bad));
    X(bad,:) = [];
    Y(bad)   = [];
end

N = size(X,1);
D = size(X,2);
fprintf("Veri temizleme sonrası veri yapısı: N=%d örnek, D=%d girdi\n", N, D);

%% 4) Hedef aralık kontrolü (MPa range)
yMin = min(Y); yMax = max(Y);
fprintf("Y aralığı kontrolü: min=%.4f, max=%.4f (beklenen MPa yaklaşık olarak [%g, %g] aralığında)\n", ...
    yMin, yMax, CFG.Y_RANGE_MPA(1), CFG.Y_RANGE_MPA(2));

if (yMin < CFG.Y_RANGE_MPA(1)) || (yMax > CFG.Y_RANGE_MPA(2))
    fprintf(2, "HATA: Hedef sütun '%s', MPa aralığıyla uyumsuz görünüyor.\n", string(YName));
    fprintf(2, "Büyük olasılıkla yanlış Y sütununu seçtiniz. CFG.Y_COL'ü düzeltin.\n");
    error("TargetRangeCheckFailed");
end

%% 5) Train/Validation/Test split
% Burada hem inputları(X) hem de target(Y) değerlerini test train validation olarak eşit şekilde 3'e ayırıyorum. 
rng(CFG.RNG_SEED, "twister");

idx = randperm(N);
nTrain = round(CFG.SPLIT_TRAIN * N);
nVal   = round(CFG.SPLIT_VAL   * N);
nTest  = N - nTrain - nVal;

if nTrain <= 0 || nVal <= 0 || nTest <= 0
    error("Invalid(Geçersiz) split sizes: train=%d, val=%d, test=%d. Fix split ratios.", nTrain, nVal, nTest);
end

iTrain = idx(1:nTrain);
iVal   = idx(nTrain+1 : nTrain+nVal);
iTest  = idx(nTrain+nVal+1 : end);

Xtr = X(iTrain,:);  Ytr = Y(iTrain);
Xva = X(iVal,:);    Yva = Y(iVal);
Xte = X(iTest,:);   Yte = Y(iTest);

fprintf("\nSplit sizes: train=%d, val=%d, test=%d\n", nTrain, nVal, nTest);

%% 6) Scaling (X girdilerini ölçekliyor (normalizasyon) ve bunu data leakage (veri sızması) yapmadan yapıyor.) 

% BURASI KATMAN 3 deki NORMALİZASYON DEĞİL- MODELE GİRMEDEN ÖNCE YAPILAN 
% ÖN İŞLEME ADIMI BURASI.
[Xtr_s, scaler] = fitMinMaxScaler(Xtr);
Xva_s = applyMinMaxScaler(Xva, scaler);
Xte_s = applyMinMaxScaler(Xte, scaler);

% Her bir giriş değişkenini 0 ile 1 arasına taşımak (min–max scaling).
% Bunu yaparken sadece train verisinden min ve max hesaplayıp, aynı dönüşümü val/test'e uygulamak.
% sadece train ÇÜNKÜ:

% Çünkü val/test'teki min–max bilgisi eğitim aşamasında bilinmemeli.
% Val/test'ten bilgi sızarsa (leakage) test performansı yapay olarak iyi görünebilir.

%% 7) ANFIS eğitimine başlamadan önce Başlangıç bulanık modeli yani initial FIS Üretiliyor. (genfis1 preferred)
trnData = [Xtr_s Ytr];
valData = [Xva_s Yva];

fprintf("\nGenerating initial FIS\n");

initFIS = [];
if hasGenfis1
    % genfis1(data, numMFs, inmftype, outmftype)
    initFIS = genfis1(trnData, CFG.MF_COUNT, char(CFG.MF_TYPE), "linear"); % Buradaki linear sugeno çıktısını lineer yapar.
else
    % genfis1 yoksa modern genfis ile GridPartition seçeneklerini kurar:
    fprintf(2, "UYARI: genfis1 bulunamadı. genfis(GridPartition) yedek fonksiyonu kullanılıyor.\n");
    optGen = genfisOptions("GridPartition");
    optGen.NumMembershipFunctions     = repmat(CFG.MF_COUNT, 1, D);
    optGen.InputMembershipFunctionType = repmat(string(CFG.MF_TYPE), 1, D);
    optGen.OutputMembershipFunctionType = "linear";
    initFIS = genfis(Xtr_s, Ytr, optGen);
end

nRulesInit = getRuleCount(initFIS);
fprintf("Initial FIS: inputs=%d, approx rules=%d\n", D, nRulesInit);

%% 8) Train ANFIS with validation
fprintf("ANFIS modeli %d epoch ile eğitiliyor (Validaiton etkinleştirildi)...", CFG.EPOCHS);

% opt diye bir ayar nesnesi oluşturarak atama yapıyorum.
opt = anfisOptions;
opt.InitialFIS = initFIS;
opt.EpochNumber = CFG.EPOCHS;
opt.ValidationData = valData;

opt.DisplayANFISInformation = 1;
opt.DisplayErrorValues      = 1;
opt.DisplayStepSize         = 1;
opt.DisplayFinalResults     = 1;

[trnFIS, trnError, stepSize, chkFIS, chkError] = anfis(trnData, opt);

% Son modeli seçiyoruz:
if ~isempty(chkError) && ~isempty(chkFIS)
    finalFIS = chkFIS;
    finalTag = "chkFIS (best validation)";
else
    finalFIS = trnFIS;
    finalTag = "trnFIS (validation model yok)";
end
fprintf("\nFinal model seçildi: %s\n", finalTag);

%% 9) Overfit yakalamaya çalışalım.
% eğer validaiton error başta düşüp sonra yükseldiyse overfit başladı demek
% oluyor şeklinde kontrol ediyoruz:
if ~isempty(chkError)
    [bestChk, bestEpoch] = min(chkError);
    lastChk = chkError(end);
    fprintf("Doğrulama RMSE'si en iyi %d. dönemde: %.6f | son dönemde: %.6f\n", bestEpoch, bestChk, lastChk);

    if (bestEpoch < CFG.EPOCHS) && (lastChk > bestChk*(1+CFG.OVERFIT_REL_INCREASE))
        fprintf(2, "Overfit sinyali: Eğitim devam ederken en iyi epoch'tan sonra chkError değeri arttı.");
        fprintf(2, "Burada chkFIS kullanmak doğru seçimdir.");
    else
        fprintf("No strong overfit signal by this simple heuristic.\n");
    end
end

%% 10) Değerlendirme
yhatTr = evalFISCompat(finalFIS, Xtr_s); % FIS ile tahmin yapmak için doğru sırayla deniyor evalFISCompat.
yhatVa = evalFISCompat(finalFIS, Xva_s);
yhatTe = evalFISCompat(finalFIS, Xte_s); 

mTr = regressionMetrics(Ytr, yhatTr);
mVa = regressionMetrics(Yva, yhatVa);
mTe = regressionMetrics(Yte, yhatTe);

fprintf("\n================= Performans (MPa) =================\n");
printMetrics("TRAIN", mTr);
printMetrics("VAL  ", mVa);
printMetrics("TEST ", mTe);

%% 11) Plots
% 11.1 Training/Validation error curves (hata eğrileri)
figure("Name","ANFIS Learning Curves");
epochs = 1:numel(trnError);
plot(epochs, trnError, "LineWidth", 1.5); grid on; hold on;
if ~isempty(chkError)
    plot(epochs, chkError, "LineWidth", 1.5);
    legend("Train RMSE","Validation RMSE","Location","northeast");
else
    legend("Train RMSE","Location","northeast");
end
xlabel("Epoch"); ylabel("RMSE");
title("ANFIS Training vs Validation Error");

% 11.2 Predicted vs Gerçek Değerler (train/val/test)
figure("Name","Predicted vs True");
scatter(Ytr, yhatTr, 18, 'filled'); hold on; grid on;
scatter(Yva, yhatVa, 18, 'filled');
scatter(Yte, yhatTe, 18, 'filled');

allY = [Ytr; Yva; Yte];
minY = min(allY); maxY = max(allY);
plot([minY maxY], [minY maxY], 'k--', 'LineWidth', 1.5);

xlabel("True Strength (MPa)");
ylabel("Predicted Strength (MPa)");
legend("Train","Val","Test","y = x","Location","best");
title("Prediction Quality (All Splits)");

% 11.3 Residual plot (test)
resTe = Yte - yhatTe;
figure("Name","Residuals (Test)");
scatter(yhatTe, resTe, 20, 'filled'); grid on; hold on;
plot([min(yhatTe) max(yhatTe)], [0 0], 'k--', 'LineWidth', 1.5);
xlabel("Predicted Strength (MPa)");
ylabel("Residual (True - Pred) (MPa)");
title("Residuals vs Predicted (Test)");

%% 12) Modeli kaydet + ölçekle + sütun eşle
modelInfo = struct();
modelInfo.cfg = CFG;
modelInfo.XNames = XNames;
modelInfo.YName = YName;
modelInfo.scaler = scaler;
modelInfo.finalTag = finalTag;
modelInfo.metricsTrain = mTr;
modelInfo.metricsVal   = mVa;
modelInfo.metricsTest  = mTe;

fprintf("\nSaving MAT model: %s\n", CFG.MODEL_MAT);
save(CFG.MODEL_MAT, "finalFIS", "modelInfo");

fprintf("Saving FIS file: %s\n", CFG.MODEL_FIS);
saveFISCompat(finalFIS, CFG.MODEL_FIS);

%% 13) Demo ve evalfis() örneğini yeniden yükleme
fprintf("\nReload demo...\n");

S = load(CFG.MODEL_MAT, "finalFIS", "modelInfo");
fisFromMat = S.finalFIS;
scaler2 = S.modelInfo.scaler;

% ilk 5 örneği kullan (RAW -> scale -> evalfis)
k = min(5, size(Xte,1));
rawX = Xte(1:k,:);
rawX_s = applyMinMaxScaler(rawX, scaler2);

yPred_fromMat = evalFISCompat(fisFromMat, rawX_s);

fprintf("Mini example (first %d test samples):\n", k);
disp(table((1:k)', Yte(1:k), yPred_fromMat, (Yte(1:k)-yPred_fromMat), ...
    'VariableNames', {'idx','Y_true_MPa','Y_pred_MPa','Residual_MPa'}));

% .fis dosyasından yeniden yükledim.
fisFromFis = loadFISCompat(CFG.MODEL_FIS);
yPred_fromFis = evalFISCompat(fisFromFis, rawX_s);
fprintf("Reloaded from .fis -> prediction delta (max abs): %.6g\n", max(abs(yPred_fromFis - yPred_fromMat)));

fprintf("\nDONE.\n");

%% ============================ FONKSİYONLAR ==============================
% CONFIG'te kullanıcı bir şey seçmiş mi, yoksa "boş" mu bırakmış diye
% kontrol fonksiyonu:
function tf = isEmptySelection(sel) 
    if isempty(sel)
        tf = true;
        return;
    end
    if isstring(sel) || ischar(sel)
        tf = strlength(string(sel)) == 0;
        return;
    end
    if iscell(sel)
        tf = isempty(sel);
        return;
    end
    tf = false;
end

% Hedef sütunu isimle veya indeksle belirtmiş olabiliriz bu fonksiyon bunu
% tek standarta çevirir.
function [name, idx] = resolveColumnByUserSelection(T, sel, label)
    varNames = T.Properties.VariableNames;
    if isnumeric(sel)
        if ~isscalar(sel) || sel < 1 || sel > width(T)
            error("%s numeric index out of range. width(T)=%d", label, width(T));
        end
        idx = sel;
        name = varNames{idx};
        return;
    end

    % İsim Tabanlı
    selStr = string(sel);
    idx = find(strcmpi(string(varNames), selStr), 1);
    if isempty(idx)
        error("%s name not found: '%s'. Use exact T.Properties.VariableNames or provide numeric index.", label, selStr);
    end
    name = varNames{idx};
end

% X tarafında birden çok sütun seçilecek. Kullanıcı bunu indeks listesiyle veya isim listesiyle verebilir.
function [names, idx] = resolveMultipleColumnsByUserSelection(T, sel, label)
    varNames = T.Properties.VariableNames;

    if isnumeric(sel)
        idx = sel(:)';
        if any(idx < 1) || any(idx > width(T))
            error("%s numeric indices out of range. width(T)=%d", label, width(T));
        end
        names = varNames(idx);
        return;
    end

    % İsim tabanlı liste
    if ischar(sel) || isstring(sel)
        sel = string(sel);
    elseif iscell(sel)
        sel = string(sel);
    end

    idx = zeros(1, numel(sel));
    for i = 1:numel(sel)
        hit = find(strcmpi(string(varNames), string(sel(i))), 1);
        if isempty(hit)
            error("%s isim bulunamadı: '%s'. Use exact T.Properties.VariableNames.", label, string(sel(i)));
        end
        idx(i) = hit;
    end
    names = varNames(idx);
end

% kolon adı vermediysek, isimlerden otomatik seçim yapar
function idx = pickVarByKeywords(varNames, keywords, label)
    vn = normalizeVarNames(varNames);
    vn = vn(:);                              % <<< CRITICAL: force column vector

    keywords = lower(string(keywords));
    scores = zeros(numel(vn),1);

    for k = 1:numel(keywords)
        scores = scores + contains(vn, keywords(k));
    end

    maxScore = max(scores);
    if maxScore == 0
        idx = [];
        return;
    end

    cands = find(scores == maxScore);

    if numel(cands) > 1
        error("Ambiguous match for %s. Candidates: %s", label, ...
            strjoin(string(varNames(cands)), ", "));
    end

    idx = cands;
end

% Sütun adlarını aramaya uygun hale getiriyor
function vn = normalizeVarNames(varNames)
    vn = lower(string(varNames));
    vn = replace(vn, "_", " ");
    vn = regexprep(vn, "[^a-z0-9]+", " ");
end

% Strategy A'da otomatik olarak 4–5 input seçer.
function XIdx = autoSelectInputsStrategyA(varNames, YIdx, numInputsA)
    % Required: Cement, Water, Age
    idxCement = pickVarByKeywords(varNames, ["cement"], "Cement");
    idxWater  = pickVarByKeywords(varNames, ["water"], "Water");
    idxAge    = pickVarByKeywords(varNames, ["age"], "Age");

    if isempty(idxCement) || isempty(idxWater) || isempty(idxAge)
        error("Strategy A requires columns matching: Cement, Water, Age. Auto-detect failed. Set CFG.X_COLS explicitly.");
    end

    % İsteğe bağlı ayalarma, öncelik sırası ile
    idxSuper = pickVarByKeywords(varNames, ["superplasticizer"], "Superplasticizer");
    idxSlag  = pickVarByKeywords(varNames, ["slag"], "Blast Furnace Slag");
    idxFly   = pickVarByKeywords(varNames, ["fly","ash"], "Fly Ash");
    idxFine  = pickVarByKeywords(varNames, ["fine","aggregate"], "Fine Aggregate");
    idxCoarse= pickVarByKeywords(varNames, ["coarse","aggregate"], "Coarse Aggregate");

    required = [idxCement idxWater idxAge];
    optional = [idxSuper idxSlag idxFly idxFine idxCoarse];
    optional = optional(~cellfun(@isempty, num2cell(optional)));

    % Build et XIdx
    XIdx = required;
    for j = 1:numel(optional)
        if ~ismember(optional(j), XIdx) && optional(j) ~= YIdx
            XIdx(end+1) = optional(j); %#ok<AGROW>
        end
        if numel(XIdx) >= numInputsA
            break;
        end
    end

    % En az 4
    if numel(XIdx) < 4
        error("Strategy A could not reach >=4 inputs. Provide CFG.X_COLS explicitly.");
    end

    % Y seçeneğini seçmediğimizden emin olalım.
    XIdx = XIdx(XIdx ~= YIdx);
    XIdx = unique(XIdx, 'stable');
end

% Leakagesız normalizasyon
function [Xs, scaler] = fitMinMaxScaler(X)
    scaler = struct();
    scaler.min = min(X, [], 1);
    scaler.max = max(X, [], 1);
    scaler.range = scaler.max - scaler.min;
    scaler.range(scaler.range == 0) = 1; 
    Xs = (X - scaler.min) ./ scaler.range;
end

function Xs = applyMinMaxScaler(X, scaler)
    Xs = (X - scaler.min) ./ scaler.range;
end

% MATLAB sürümlerinde evalfis çağrısının argüman sırası değişebiliyormuş.
% Bu fonksiyon iki olasılığı da dener. TAVSİYE ÜZERİNE EKLENDİ.
function y = evalFISCompat(fis, X)
    try
        y = evalfis(fis, X);
    catch
        y = evalfis(X, fis);
    end
    y = double(y(:));
end

% FIS modelinin formatına göre seçer. (Eski ve yeni oalrak)
function nRules = getRuleCount(fis)
    nRules = NaN;
    try
        nRules = numel(fis.Rules);
        return;
    catch
    end
    try
        nRules = numel(fis.rule);
        return;
    catch
    end
end

% RMSE, MAE, R² hesaplamak.
% RMSE: kare hata ortalamasının kökü
%MAE: mutlak hata ortalaması
function m = regressionMetrics(yTrue, yPred)
    yTrue = double(yTrue(:));
    yPred = double(yPred(:));
    err = yTrue - yPred;

    m = struct();
    m.RMSE = sqrt(mean(err.^2));
    m.MAE  = mean(abs(err));
    sse = sum(err.^2);
    sst = sum((yTrue - mean(yTrue)).^2);
    if sst <= 0
        m.R2 = NaN;
    else
        m.R2 = 1 - (sse/sst);
    end
end

% metrikleri tek formatta yazdırır.
function printMetrics(tag, m)
    fprintf("%s | RMSE=%.4f  MAE=%.4f  R2=%.4f\n", tag, m.RMSE, m.MAE, m.R2);
end

function saveFISCompat(fis, fileName)
    % Prefer writeFIS (new). Fallback to writefis (legacy).
    try
        writeFIS(fis, fileName);
    catch
        try
            writefis(fis, fileName);
        catch ME
            fprintf(2, "ERROR saving FIS: %s\n", ME.message);
            error("Cannot save FIS. Ensure Fuzzy Logic Toolbox is installed and supports writeFIS/readfis.");
        end
    end
end

function fis = loadFISCompat(fileName)
    % Prefer readfis (new supports objects). Fallback to readfis legacy if needed.
    try
        fis = readfis(fileName);
    catch
        try
            fis = readfis(char(fileName));
        catch ME
            fprintf(2, "ERROR loading FIS: %s\n", ME.message);
            error("Cannot load FIS. Ensure file exists and Fuzzy Logic Toolbox is installed.");
        end
    end
end
