# Concrete Compressive Strength Prediction with ANFIS (MATLAB)

Project that implements a **classic ANFIS (Adaptive Neuro‑Fuzzy Inference System)** pipeline to predict **concrete compressive strength (MPa)** from mix proportions and curing age.

The purpose of the project:
- Set up a clean regression workflow (train/validation/test split, leakage-free preprocessing),
- Train and evaluate a Sugeno-type ANFIS model in MATLAB,
- Export/reload trained models reproducibly.



## Problem

Predict **concrete compressive strength** from mixture components and **age**. The relationship is **highly nonlinear**.


## Dataset

This project uses the **UCI Concrete Compressive Strength** dataset (1030 samples, 8 input variables, 1 target).  
- Source (UCI): https://archive-beta.ics.uci.edu/dataset/165/concrete%2Bcompressive%2Bstrength  
- License: **CC BY 4.0** (credit required)

### Variables (canonical)
- Cement, Blast Furnace Slag, Fly Ash, Water, Superplasticizer, Coarse Aggregate, Fine Aggregate (kg/m³)
- Age (days)
- Target: Concrete compressive strength (MPa)

### What I actually used in the model
To keep the ANFIS rule base tractable (grid partitioning can explode rules), this run uses **5 inputs**:

- Cement (kg/m³)
- Water (kg/m³)
- Age (days)
- Superplasticizer (kg/m³)
- Blast Furnace Slag (kg/m³)

Target:
- Concrete compressive strength (MPa)



## Method

### ANFIS configuration (Sugeno-type)
- Initial FIS: **grid partition** (`genfis1` if available, otherwise `genfis(GridPartition)`)
- Input membership functions: **Gaussian (`gaussmf`)**
- Membership functions per input: **2**
- Inputs used: **5**
- Approx. rule count: **2^5 = 32 rules**
- Output MF: **linear** (first-order Sugeno)

### Training setup
- Data split: **70% train / 15% validation / 15% test**
- Preprocessing: **min–max scaling fitted on train only** (applied to val/test using train scaler)
- Training: `anfis` with `ValidationData` enabled, **120 epochs**
- Reproducibility: fixed random seed (**42**)

## Results
Metrics computed on each split (MPa):

TRAIN: RMSE=4.3397, MAE=3.1558, R2=0.9312 
VAL: RMSE=7.6945, MAE=5.2297, R2=0.8083
TEST: RMSE=7.3726, MAE=5.0972, R2=0.7946

**Interpretation:**
- There is a noticeable generalization gap (train RMSE vs. test RMSE), so the model is not perfectly regularized.
- Validation error tends to flatten / slightly increase after early epochs → early stopping would likely be beneficial.


## Figures
Place your plots under `figures/` (recommended filenames shown below):


### Prediction Quality (All Splits)
![Predicted vs True](figures/predicted_vs_true.png)

### Residuals vs Predicted (Test)
![Residuals](figures/residuals_test.png)

### ANFIS Learning Curves (Train vs Validation RMSE)
![Learning Curves](figures/learning_curves.png)


## Repo layout

```
.
├── src/
│   └── main.m
├── models/
│   ├── anfis_concrete_model.fis
│   └── anfis_concrete_model.mat
├── figures/
│   ├── predicted_vs_true.png
│   ├── residuals_test.png
│   └── learning_curves.png
├── data/               # optional (see note below)
│   └── Concrete_Data.xls
└── README.md
```



## How to run

### Requirements
- MATLAB + **Fuzzy Logic Toolbox** (functions: `anfis`, `genfis1` / `genfis`, `evalfis`)

### Steps
1. Download the dataset (UCI link above) and place it as:
   - `Concrete_Data.xls` in the repo root **or**
   - `data/Concrete_Data.xls` and update `CFG.DATA_FILE` in `main.m`.

2. Run:
```matlab
cd src
main
```

The script will:
- read the dataset,
- split train/val/test,
- fit a leakage-free scaler on train,
- generate the initial FIS,
- train ANFIS,
- print RMSE/MAE/R²,
- save trained models:
  - `anfis_concrete_model.mat` (FIS + scaler + metadata)
  - `anfis_concrete_model.fis` (portable FIS)


## Model export & reload (what’s included)

- `.mat` contains: trained FIS, scaler parameters, selected inputs, and metrics.
- `.fis` is a portable FIS file you can reload with `readfis`.

The script also includes a small “reload demo” section to verify that reloaded models produce consistent predictions.


## Limitations / next steps

If I were to evolve this into a stronger portfolio piece:
- add **baseline models** (linear regression, random forest, gradient boosting) for comparison,
- run **k-fold cross-validation** (single random split can mislead),
- tune **MF count / MF type / input subset** systematically,
- implement **early stopping** at the best validation epoch,
- investigate **non-physical predictions** (e.g., negative MPa) and apply constraints or target transforms.


## References
- J.-S. R. Jang, “ANFIS: Adaptive-Network-based Fuzzy Inference System,” *IEEE Transactions on Systems, Man, and Cybernetics*, 1993.
- UCI Machine Learning Repository: Concrete Compressive Strength (CC BY 4.0): https://archive-beta.ics.uci.edu/dataset/165/concrete%2Bcompressive%2Bstrength
- MATLAB documentation: `anfis`, `genfis1`, `genfis` (Fuzzy Logic Toolbox)


## ANFIS
![The Architecture of ANFIS](The-architecture-of-ANFIS.png)

## Additional Information

* **Developer**: [Fatih AYIBASAN] (Computer Engineering Student)
* **Email**: [fathaybasn@gmail.com]

---