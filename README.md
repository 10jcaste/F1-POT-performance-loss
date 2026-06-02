# f1-POT-performance-loss

POT-based extreme value analysis of Formula 1 lap-time data from OpenF1.

This repository contains the code used to study extreme relative performance losses in Formula 1 using lap-time data from the 2024 season. The analysis applies a Peaks Over Threshold approach from Extreme Value Theory to model unusually large losses of race pace within individual stints.

The project was developed as part of an undergraduate thesis on Quantitative Risk Management and Extreme Value Theory.

## Overview

The aim of this project is to analyze how large relative performance losses can become during a Formula 1 race when lap times are compared within homogeneous race segments.

For each lap, a relative performance-loss variable is defined as

[
R_i = \frac{T_i - T_{\min,s}}{T_{\min,s}} \cdot 100,
]

where:

* (T_i) is the lap time of lap (i),
* (T_{\min,s}) is the fastest lap by the same driver within the same stint,
* (R_i) is the relative performance loss, expressed as a percentage.

The normalization is performed within each stint rather than across the full race or the full driver sample. This makes the metric more comparable across drivers, tyre compounds, tyre ages, fuel loads and race phases.

## Data source

The data are obtained from the OpenF1 API, an open-source API that provides Formula 1 timing, session, driver and stint data.

The analysis uses data from all 2024 Formula 1 races and relies mainly on the following OpenF1 endpoints:

* `sessions`
* `laps`
* `stints`
* `drivers`

Pit-out laps are removed, and relative performance losses above 10% are excluded because they are interpreted as non-representative race-pace laps, usually associated with incidents, severe traffic, safety-car effects, strategy anomalies or other abnormal race situations.

## Methodology

The analysis follows these steps:

1. Download all 2024 race sessions from OpenF1.
2. Retrieve lap, stint and driver data for each race.
3. Match each lap to its corresponding stint.
4. Compute the best lap time achieved by each driver within each stint.
5. Construct the stint-normalized relative performance-loss variable.
6. Remove pit-out laps and extreme non-representative observations above 10%.
7. Select a high threshold using the 95th percentile of the cleaned sample.
8. Fit a Generalized Pareto Distribution to the threshold exceedances.
9. Estimate the shape and scale parameters of the fitted tail model.
10. Estimate the upper endpoint of the performance-loss distribution when the fitted shape parameter is negative.
11. Compare the 95th-percentile threshold with the 90th-percentile threshold as a basic threshold-stability check.

## Main results

After data cleaning, the final sample contains

[
n = 24128
]

laps.

Using the 95th percentile as the POT threshold gives:

[
u = 5.212105,
\qquad
N_u = 1207,
\qquad
N_u/n = 0.05002487.
]

The fitted Generalized Pareto Distribution gives:

[
\hat{\sigma} = 2.692172,
\qquad
\hat{\xi} = -0.5383055.
]

The corresponding standard errors are:

[
se(\hat{\sigma}) = 0.09904884,
\qquad
se(\hat{\xi}) = 0.02766618.
]

Since the estimated shape parameter is negative, the fitted tail is bounded above. The estimated upper endpoint is

[
\hat{\omega}
============

# u - \frac{\hat{\sigma}}{\hat{\xi}}

10.21330.
]

Therefore, under the fitted POT-GPD model, extreme relative performance losses are estimated to be bounded at approximately 10.21% relative to the best lap of the same driver within the same stint.

As a threshold-stability check, the same analysis was repeated using the 90th percentile as threshold. This produced:

[
u_{0.90} = 3.300020,
\qquad
\hat{\xi}*{0.90} = -0.4604229,
\qquad
\hat{\omega}*{0.90} = 10.49489.
]

The negative shape estimates and similar upper endpoints support the interpretation of a bounded upper tail.

## Repository structure

```text
f1-POT-performance-loss/
│
├── README.md
├── LICENSE
├── f1_pot_performance_loss.R
│
├── data/
│   └── clean_lap_data_2024.csv
│
├── results/
│   ├── pot_results_f1_2024.csv
│   └── threshold_comparison_pot_f1_2024.csv
│
└── figures/
    ├── figure_1_distribution_threshold.jpg
    ├── figure_2_gpd_exceedances.jpg
    ├── figure_3_gpd_qqplot.jpg
    └── figure_4_return_levels.jpg
```

## Requirements

The analysis is written in R and uses the following packages:

```r
install.packages(c(
  "httr2",
  "jsonlite",
  "dplyr",
  "readr",
  "stringr",
  "purrr",
  "ismev",
  "ggplot2",
  "evd"
))
```

## Reproducibility

The main script downloads the data directly from the OpenF1 API and reproduces the full analysis, including data processing, cleaning, POT-GPD fitting, threshold comparison and figure generation.

Because the script queries the OpenF1 API repeatedly, pauses are included between batches of requests to reduce the risk of HTTP 429 errors caused by excessive request frequency.

## Interpretation

The negative estimated shape parameter indicates that the fitted extreme tail belongs to the Weibull-type domain, meaning that the distribution of relative performance losses has a finite upper endpoint.

In practical terms, this suggests that, after excluding non-representative laps, extreme race-pace losses in the 2024 Formula 1 season are bounded. Under the chosen POT-GPD model with the 95th-percentile threshold, this upper bound is estimated at approximately 10.21%.

This result should be interpreted within the modelling framework and the data-cleaning criteria used in the analysis. In particular, the upper endpoint refers to relative losses measured with respect to the best lap of the same driver within the same stint, not to absolute lap-time losses over an entire race.

## License

This project is licensed under the MIT License.
