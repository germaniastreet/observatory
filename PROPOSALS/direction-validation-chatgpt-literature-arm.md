# Direction-validation study — ChatGPT literature arm (input file)
**Provenance:** ChatGPT replies to the owner, 2026-10-25, from the researcher-shortlist thread, in response to the literature-arm instruction embedded in the study charter. Relay-protocol note: ChatGPT has no disk access; the owner pasted these replies back. Three parts, in order:
- **Part A** — main literature arm: Q1 construct validity, Q2 bespoke-vs-established estimators, Q3 voice-SaMD precedents, Q4 honest-measurement practices, Q5 blind-spot audit + prioritized 15-paper reading list + consolidated verdict ("sound-with-reservations").
- **Part B** — ChatGPT's self-correction on prediction vs measurement (embeddings/Whisper comparisons: what they do and do not justify).
- **Part C** — frontier supplement: learned speech representations (emotion2vec), everyday-speech studies (PNAS Nexus 2026; npj Digital Medicine 2026 voice diaries), depression-detection external validation (Nature Communications 2026; cross-site Annals of General Psychiatry 2026), LISTEN benchmark (EACL 2026), VoxParadox (ICML 2026), the smaller-circle advantage analysis, and a proposed five-layer architecture.
**Status: INPUT, NOT VERIFIED.** Per the study charter, the Hermes study must cross-check every citation, number, and claim in this file before relying on it, and record disagreements rather than silently reconciling them. ChatGPT itself flags its verification status per source and has already self-corrected twice in this thread (DALI≠DAIC; Kintsugi shut down commercial operations 2026-02-10).

---

## Part A — main literature arm (verbatim)

**Verdict: sound-with-reservations as a development direction; not yet a validated measurement instrument.** Transcript-independent acoustic analysis is defensible. Synthetic accuracy, provenance, and conservative abstention do not yet establish accuracy on real speech, reliable personal trends, or mood validity.

I treated the Observatory findings in your brief as supplied evidence. I did not inspect the experiments, recordings, or implementation. Below, **published evidence** means verified literature or official documentation; **recommendations** are my assessment of what Observatory should do next.

**1. Construct validity: what do these acoustic features actually measure?**

The critical distinction is between three claims:

1. “This retained audio has these acoustic properties.”
2. “These properties reliably describe how this person’s speech changed.”
3. “Those changes indicate a change in mood, depression, or another psychological state.”

Evidence for the first does not establish the second or third.

**Strongest supporting evidence**

There is credible evidence that acoustic speech characteristics contain information associated with depression and affect.

- **Mundt et al. (2012)** studied 105 adults with major depression over four weeks. Previously developed relationships between speech changes and treatment outcomes replicated in a different study. This is more relevant to longitudinal monitoring than a simple depressed-versus-control classifier, although the acoustic analysis was exploratory and used structured telephone collection. [Study](https://pubmed.ncbi.nlm.nih.gov/22541039/)
- **Wiseman et al. (2025)** compared 66 people with major depression against 54 controls. Depressed participants spoke more slowly, paused more, and had lower mean pitch. Reported effect sizes included approximately η² = **0.15 for speech rate**, **0.08 for pausing**, and **0.03 for mean pitch**. [Study](https://www.nature.com/articles/s41398-025-03728-2)
- Vocal-affect experiments demonstrate that configurations of acoustic cues convey emotional expression above chance. But much foundational evidence concerns performed emotional expressions and listeners’ judgments, which differ from measuring a speaker’s internal experience. [Banse and Scherer](https://pubmed.ncbi.nlm.nih.gov/8851745/)

**Strongest contradicting or limiting evidence**

Two findings directly challenge a simplistic “voice feature tracks mood” interpretation:

- A **2026 systematic review and meta-analysis** included 17 studies, but only six supplied usable mean-F0 data. The pooled difference was approximately **−1.82 Hz**, **not statistically significant, p = .56**. Other acoustic parameters could not be pooled because reporting was insufficient. This undermines treating lower average F0 as an established general depression marker. [Meta-analysis](https://pubmed.ncbi.nlm.nih.gov/42038195/)
- In the Wiseman study, **none of the acoustic features significantly tracked depression severity**, despite case-control differences. Pitch variance did not distinguish the groups. Group discrimination therefore did not establish a severity meter. Its combined acoustic-and-language score also cannot validate Observatory’s acoustic-only subset. [Study](https://www.nature.com/articles/s41398-025-03728-2)

There is no defensible universal effect size for “depression causes longer pauses” across tasks, languages, recording systems, and populations. The literature is heterogeneous; a single favorable study should not supply your interpretation threshold.

| Observatory feature | Defensible immediate construct | Main validity limitation |
|---|---|---|
| **F0 statistics** | Estimated vocal-fold repetition frequency in accepted voiced frames | Voicing selection, octave errors, phonetic content, register, and task affect the result; F0 is not identical to perceived pitch |
| **Intensity in dBFS** | Digital recording level under a specified computation | Not calibrated vocal sound pressure or vocal effort; microphone distance, gain, and processing can change it |
| **Pause/silence measures** | Durations classified according to an explicit segmentation rule | Low energy is not necessarily silence; silence is not necessarily a behavioral pause |
| **Detected nucleus rate** | Accepted acoustic peaks per specified denominator | Not validated syllables, words, articulation rate, or information rate |
| **Jitter/shimmer** | Cycle-to-cycle period/amplitude perturbation under suitable signal conditions | Not interchangeable with frame-level F0 variability or intensity variability; requires separate validation |

Praat explicitly warns that jitter, shimmer, and voicing measurements are not automatically comparable across programs. Its recommended analysis method also differs between intonation analysis and voice perturbation analysis. [Praat comparison documentation](https://fon.hum.uva.nl/praat/manual/Voice_5__Comparison_with_other_programs.html), [method selection](https://www.fon.hum.uva.nl/praat/manual/how_to_choose_a_pitch_analysis_method.html).

**Relationship to established feature sets**

Your selection covers familiar **prosodic and temporal feature families**, but it is not an implementation of an established feature set:

- **GeMAPS/eGeMAPS:** standardizes specific descriptors, functionals, and extraction choices; includes voice-quality and spectral information beyond your present core. Your dBFS measure is not automatically equivalent to its loudness descriptor, and your nucleus detector is not automatically equivalent to its temporal descriptors. [GeMAPS paper](https://doi.org/10.1109/TAFFC.2015.2457417)
- **COVAREP:** provides published implementations of complementary voice-analysis methods, including source-related information. It is a useful comparator, not proof that every available feature is reliable or useful. [Paper and repository](https://github.com/covarep/covarep)
- **Praat:** is an analysis environment with consequential settings and algorithms, not a single invariant reference. Record the exact version, method, bounds, and settings.

A small validated subset is preferable to a larger unvalidated inventory. However, it cannot inherit the performance of studies that used richer feature sets.

**What the named benchmarks can establish**

| Resource | Appropriate use | What it cannot establish for Observatory |
|---|---|---|
| **IEMOCAP** | Stress-testing expressive speech; comparison with scripted/improvised speech and annotations | Validity for private, spontaneous reflections or experienced mood |
| **CREMA-D / RAVDESS** | Controlled emotional-expression and perception experiments | That performed/perceived emotion equals internal state |
| **DEAP / MAHNOB-HCI** | Lessons about synchronized modalities, stimulus protocols, and self-report | Validation of a voice-only reflection instrument |
| **AVEC / DAIC-WOZ / E-DAIC** | Standardized depression/affect comparisons and evaluation protocols | Generalization to one person’s daily speech or your estimators |

These limitations follow from the datasets’ collection designs. [IEMOCAP](https://sail.usc.edu/iemocap/iemocap_release.htm), [CREMA-D](https://pmc.ncbi.nlm.nih.gov/articles/PMC4313618/), [RAVDESS](https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0196391), [DEAP](https://research.utwente.nl/en/publications/deap-a-database-for-emotion-analysis-using-physiological-signals/), [MAHNOB-HCI](https://research.utwente.nl/en/publications/a-multimodal-database-for-affect-recognition-and-implicit-tagging/), [AVEC](https://arxiv.org/abs/1907.11510).

I could not verify an applicable affect/depression challenge called **DALI**. The established DALI resource I located concerns synchronized music, lyrics, and singing notes. Do not silently substitute DAIC for DALI; the intended reference needs resolution. [DALI paper](https://arxiv.org/abs/1906.10606)

**Assessment:** Your current decision to produce no mood labels is justified. At this stage, describe outputs as acoustic measurements of retained speech—not established measures of mood.

**2. Bespoke versus established estimators**

**Strongest support:** NCCF is a legitimate method family. RAPT, for example, uses normalized cross-correlation. A bespoke implementation is not scientifically disqualified because it is bespoke. [Algorithm-comparison study](https://pmc.ncbi.nlm.nih.gov/articles/PMC4032429/)

**Strongest contradiction:** The difficult parts of F0 estimation include real voiced/unvoiced transitions, subharmonics, irregular phonation, noise, and candidate selection. Successful synthetic tests do not establish those behaviors. Established software also disagrees, so matching one package is evidence of comparability—not ground truth.

The cost of bespoke estimation is that **you own the evidence for every consequential difference**: frame geometry, preprocessing, candidate generation, interpolation, voicing gates, continuity rules, and aggregation.

My recommended validation sequence is:

| Validation layer | Required evidence |
|---|---|
| **Algorithm verification** | Known-frequency signals, sweeps, missing fundamentals, amplitude changes, noise, clipping, onset/offset cases, and explicit octave-error tests |
| **Reference speech** | Real speech with independent F0 references, ideally including electroglottographic/laryngographic recordings |
| **Method comparison** | Identical audio through your implementation and pinned reference implementations; reconcile differing definitions |
| **Target-user recordings** | Manually reviewed examples spanning ordinary speech, soft speech, creak, laughter, breath, noise, and interruptions |
| **Trend validation** | Demonstrate that error and repeatability are small enough to resolve the changes you intend to report |

Edinburgh’s pitch-evaluation resource contains speech and laryngeal reference contours: useful evidence beyond synthetic oscillators. [Reference resource](https://www.cstr.ed.ac.uk/research/projects/fda/)

Report at least:

- Voiced/unvoiced errors and accepted coverage.
- F0 bias, absolute error, octave errors, and tail errors.
- Session-summary agreement, not only frame accuracy.
- Performance by relevant conditions, including difficult speech.
- Uncertainty that respects clustering within recordings.

Do not use Pearson correlation as the primary acceptance criterion: two estimators can correlate strongly while differing systematically. Use bias and limits of agreement, with repeated-measure methods where appropriate. [Bland–Altman](https://pubmed.ncbi.nlm.nih.gov/2868172/)

For the nucleus detector, the original **de Jong–Wempe** method used intensity peaks plus voicing and was evaluated against human syllable counts in Dutch corpora. That supports transcript-independent estimation in principle; it does not validate your adaptation, English reflections, or your thresholds. Retain the “detected nucleus” label and validate event precision/recall, counts, and rate error against annotation. [Original paper](https://www.fon.hum.uva.nl/archive/2009/2009-brm-JongWempe.pdf)

**Assessment:** Keep the bespoke estimator if it meets predefined error tolerances and is maintainable. Replacing it with Praat/openSMILE would reduce implementation burden, but would not eliminate analytical validation.

**3. Voice-based SaMD precedents**

The strongest lesson is that these organizations validate **specific outputs against specific comparators**. Their existence does not validate a generic “voice understands mental health” claim.

| Precedent | Verified validation evidence | Regulatory conclusion I can support |
|---|---|---|
| **Ellipsis Health** | A 2025 retrospective study analyzed real case-management calls using acoustic **and semantic** models, with questionnaire content removed. Blind-set PHQ-8 agreement: concordance **0.54**, MAE **4.06 points**; threshold AUCs approximately **0.79–0.83** across development/blind evaluations. | I did not verify an FDA authorization for this depression output. Published validation and commercial deployment are not authorization. |
| **Sonde Health** | A prospective four-week study included **104 psychiatric outpatients**, comparing a vocal-biomarker score with **M3 self-report** symptom measures. | I did not verify FDA authorization for Mental Fitness. Treat it as a published monitoring precedent, not an established cleared diagnostic. |
| **Kintsugi** | A published study compared voice output against **PHQ-9 ≥10**: sensitivity **71.3%**, specificity **73.5%**. This is questionnaire-threshold detection, not independently adjudicated diagnosis. | Authorization **not verified**. Its public materials contain ambiguous FDA-pathway language and an investigational-device disclaimer. |
| **Winterlight** | Published work uses structured speech/language tasks, clinical group comparisons, and composite scores in cognitive disorders. | A 2023 study explicitly described its assessment as investigational and not FDA-approved at that time. I did not establish a subsequent authorization. |
| **Strados RESP** | An adjacent acoustic-monitoring precedent: acquisition, recording, storage, and clinician review of lung sounds. | **Verified FDA 510(k), K220893, April 27, 2022.** This is a hardware/software respiratory platform—not authorization for voice-based mood inference. |

Sources: [Ellipsis study](https://pmc.ncbi.nlm.nih.gov/articles/PMC12223686/), [Sonde study](https://www.frontiersin.org/journals/psychiatry/articles/10.3389/fpsyt.2024.1342835/full), [Kintsugi study](https://pubmed.ncbi.nlm.nih.gov/39805690/), [Winterlight study](https://pmc.ncbi.nlm.nih.gov/articles/PMC10683975/), [FDA Strados record](https://www.accessdata.fda.gov/scripts/cdrh/cfdocs/cfpmn/pmn.cfm?ID=K220893), [cleared intended use](https://www.accessdata.fda.gov/cdrh_docs/pdf22/K220893.pdf).

**Strongest support for your direction:** Sonde’s repeated voice-journaling design is reasonably close to your collection context; Strados demonstrates that a narrowly scoped acoustic acquisition/review function can be a meaningful medical-device product.

**Strongest limitation:** None establishes that your small feature set, on-device implementation, or single-person free reflections produce equivalent results. Sonde’s analysis also aligned voice samples across windows around symptom questionnaires; that is not validation of instantaneous mood. Winterlight includes language-dependent tasks absent from your present acoustic-only direction.

**Important correction:** Kintsugi announced on **February 10, 2026** that it was shutting down commercial operations and releasing work. My earlier suggestion that you approach it as an operating employer was insufficiently checked. Its announcement is also not an FDA decision record. [Company announcement](https://www.kintsugihealth.com/blog/open-source)

**Implication for Observatory:** Building traceability now can preserve useful evidence. It does not mean today’s personal-use validation will satisfy a later clinical claim. A changed population, recording protocol, algorithm, or intended output may require substantially new validation. FDA classification depends on intended use; “submit later” is not itself a development category. [FDA explanation](https://www.fda.gov/medical-devices/classify-your-medical-device/how-determine-if-your-product-medical-device)

**4. Honest-measurement practices: strengths and omissions**

The closest organizing framework is **V3: verification, analytical validation, clinical validation**. Your brief describes substantial verification work, but acknowledges that real-speech analytical validation remains missing; clinical validation has not begun. [Goldsack et al.](https://www.nature.com/articles/s41746-020-0260-4)

**Strongest supporting evidence:** Preregistration helps separate hypothesis testing from exploratory decisions, while V3 explicitly requires evidence linking outputs to reference measurements and intended use. [Nosek et al.](https://pubmed.ncbi.nlm.nih.gov/29531091/)

**Strongest counterevidence to “good process implies trustworthy trends”:** Stegmann et al. evaluated commonly used speech/language features in three clinical task sets. Median ICCs ranged **0.02–0.55**, and median within-subject coefficients of variation **29–79%**. Those figures do not describe your features specifically, but demonstrate that widely used extraction methods can yield poorly repeatable clinical measurements. [Study](https://pubmed.ncbi.nlm.nih.gov/33442573/)

| Your practice | Assessment | What it does not solve |
|---|---|---|
| Frozen thresholds and documented amendments | Consistent with confirmatory practice | Thresholds can still be poorly chosen; freezing them does not validate them |
| Coverage-scoped analysis | Appropriate | Retained spans may systematically differ from missing spans |
| Unavailable = null | Correct representation | Null needs a reason; a real measured zero must remain possible |
| Abstention around discontinuities | Appropriate | Must include the estimator’s entire dependency region, not just the reported frame |
| Hashed configuration/versioning | Strong traceability | A hash does not establish provenance completeness, accuracy, or uncertainty |

I cannot substantiate that these practices **exceed biomedical standards** as a whole. Some are more explicit than typical exploratory papers; none replaces validation.

The main missing elements are:

1. **Operational definitions.** Define every denominator, aggregation rule, admissible signal, and target quantity before scoring.
2. **Reference annotation.** Independent annotation for speech activity, pauses, nuclei, and reviewed F0; ambiguous examples need adjudication and uncertainty.
3. **Repeatability and reproducibility.** Separate re-running the same file, re-recording the same task, changing room/distance/device, and genuine behavioral change.
4. **Within-person error and minimum detectable change.** Estimate absolute variability under stable conditions. A statistically visible difference is not necessarily meaningful.
5. **Prospective held-out evaluation.** Future sessions must remain untouched while thresholds are developed.
6. **Robustness and change control.** Record device, microphone route, OS, gain/processing conditions, and algorithm versions; reprocess old audio or conduct bridging studies after consequential changes.
7. **Missingness and failure analysis.** Report excluded duration and reasons, and whether exclusions concentrate in particular speaking styles.
8. **Independent review.** Have someone other than the estimator’s author inspect annotations, errors, and the acceptance analysis.

For a single user, a population ICC may be uninformative or undefined in the intended sense. Prioritize within-person error, bias, and repeatability; do not import an ICC threshold without choosing the appropriate design. **Minimum detectable change is also different from minimum clinically important change.** [Reliability guidance](https://pmc.ncbi.nlm.nih.gov/articles/PMC4913118/)

Multi-speaker validation is not necessary to prove a narrowly stated personal-use result. It becomes necessary if you claim broader applicability. Even one-person use requires testing that person’s relevant conditions and future sessions.

**5. Adversarial blind-spot audit**

The first reviewer objection would be:

> You have specified trustworthy bookkeeping for outputs whose accuracy on the intended speech has not yet been established.

The next objections would be these.

**A. The “measurement-grade” claim is premature.**  
That is an ambition until you can state error, limits of use, and repeatability for each output.

**B. “Transcript-independent” does not mean “language-independent.”**  
Phonetic composition, topic, sentence construction, emotional display, and speaking task affect acoustics. You can remove transcription as a dependency without removing linguistic confounding.

**C. Your silence construct may be wrong.**  
Energy thresholds can confuse quiet speech, breath, background noise, and actual absence of speech. Unvoiced consonants are speech. Validation should distinguish speech activity, periodic voicing, low-energy intervals, and behavioral pauses.

**D. dBFS trends can primarily track the recording setup.**  
A phone moved farther away can create an apparent behavioral change. Smartphone studies found good agreement for some frequency-derived measures but systematic problems for amplitude-related measures such as shimmer. [Mobile-versus-studio comparison](https://pubmed.ncbi.nlm.nih.gov/36379826/)

**E. Voicing gates can manufacture reassuring results.**  
An estimator may be accurate only because it rejects creaky, soft, irregular, or expressive speech. You must report error and coverage together, including which behaviors disappear. The general abstention literature formalizes this risk–coverage tradeoff; applying it to your acoustic gates is my recommendation. [Selective prediction](https://proceedings.mlr.press/v97/geifman19a)

**F. Splice exclusion needs a dependency-aware margin.**  
Filters, envelopes, normalization, smoothing, and pitch trackers may use samples outside the nominal output window. Excluding only windows visibly crossing a splice can still leave contaminated results.

**G. A partial recording cannot establish full-session behavior.**  
“Pause fraction within validated retained spans” is defensible. “You paused less in this reflection” may not be, especially when interruptions or failures preferentially remove particular behavior.

**H. Frames are not independent experiments.**  
Thousands of overlapping frames from one recording do not provide thousands of independent observations. Evaluate at recording/session level and use inference that respects temporal dependence.

**I. Self-reflection is a task, not a neutral sample of everyday behavior.**  
A stronger design pairs free reflection with a short standardized task, keeping their results separate. This helps distinguish changing content from changing production.

**J. Acoustic capture does not establish bodily or psychological mechanism.**  
Picard’s physiological work, DEAP, and MAHNOB-HCI used additional recorded channels and elicitation protocols. Their findings justify examining complementary signals; they do not make voice a substitute for ECG, EDA, or self-report.

**K. Future multimodal work will multiply validation obligations.**  
From the Morency/Baltrušaitis/Pantic tradition, the relevant lesson is explicit observable behavior and annotation—not automatic access to emotion. Synchronization errors, facial occlusion, disagreement between modalities, and missingness will need their own tests. [OpenFace](https://github.com/TadasBaltrusaitis/OpenFace), [affect-recognition survey](https://pubmed.ncbi.nlm.nih.gov/19029545/)

**L. Benchmark success can reflect shortcuts.**  
A peer-reviewed DAIC-WOZ analysis found that interviewer prompts could reveal discriminative shortcuts around mental-health questioning. This directly challenges importing benchmark accuracy as evidence of physiological sensitivity. [ClinicalNLP study](https://aclanthology.org/2024.clinicalnlp-1.8.pdf)

The missing expert communities are therefore not just affective computing: they include **clinical speech measurement, phonetics, voice science, metrology, longitudinal statistics, and human annotation**. Stegmann, Berisha, Liss, Vogel, Mundt, de Jong, Wempe, Boersma, Degottex, and colleagues are particularly relevant additions to your expert map.

**Prioritized reading: 15 papers/resources**

“Verified” below describes what I checked, not independent replication of the paper’s results.

| Priority | Paper/resource | Why read it | Verification status |
|---|---|---|---|
| 1 | [Goldsack et al., V3 framework](https://www.nature.com/articles/s41746-020-0260-4) | Establishes why capture verification, measurement validation, and clinical validation are separate obligations. | Peer-reviewed framework; article verified |
| 2 | [Stegmann et al., Repeatability of Commonly Used Speech and Language Features](https://pubmed.ncbi.nlm.nih.gov/33442573/) | Directly challenges the assumption that established features yield reliable personal trends. | Peer-reviewed; abstract and numerical results verified |
| 3 | [Bland & Altman, measurement agreement](https://pubmed.ncbi.nlm.nih.gov/2868172/) | Supplies the essential distinction between correlation and interchangeable measurements. | Peer-reviewed methods paper; record verified |
| 4 | [Eyben et al., GeMAPS](https://doi.org/10.1109/TAFFC.2015.2457417) | Gives a principled feature baseline and exposes implementation differences hidden by familiar feature names. | Peer-reviewed; methods verified |
| 5 | [de Jong & Wempe, syllable-nucleus detection](https://www.fon.hum.uva.nl/archive/2009/2009-brm-JongWempe.pdf) | Supports transcript-free rate estimation while making clear that your adaptation needs its own validation. | Peer-reviewed; original paper verified |
| 6 | [Praat method-selection and comparison documentation](https://www.fon.hum.uva.nl/praat/manual/how_to_choose_a_pitch_analysis_method.html) | Explains why F0 and perturbation estimates depend on method and purpose. | Official technical documentation; verified |
| 7 | [COVAREP](https://github.com/covarep/covarep) | Provides published reference implementations and complementary voice-source measures for comparison. | Official repository and conference-paper provenance verified |
| 8 | [Cantor-Cutiva et al., depression acoustics meta-analysis](https://pubmed.ncbi.nlm.nih.gov/42038195/) | Challenges general claims about lower mean F0 and exposes insufficient quantitative reporting. | Peer-reviewed; abstract and pooled result verified |
| 9 | [Mundt et al., depression severity and treatment response](https://pubmed.ncbi.nlm.nih.gov/22541039/) | Provides longitudinal support stronger than a simple case-control classifier. | Peer-reviewed; design and replication claims verified in abstract |
| 10 | [Wiseman et al., objective speech measures](https://www.nature.com/articles/s41398-025-03728-2) | Shows that group differences can coexist with absent severity associations. | Peer-reviewed; article and results verified |
| 11 | [Mobile-versus-studio acoustic comparison](https://pubmed.ncbi.nlm.nih.gov/36379826/) | Identifies recording-dependent biases relevant to intensity and shimmer. | Peer-reviewed; abstract/results verified |
| 12 | [Banse & Scherer, acoustic profiles of vocal emotion](https://pubmed.ncbi.nlm.nih.gov/8851745/) | Supports expressive acoustic information while exposing the gap between portrayed emotion and internal state. | Peer-reviewed; abstract and original-paper material checked |
| 13 | [DAIC-WOZ therapist-prompt shortcut study](https://aclanthology.org/2024.clinicalnlp-1.8.pdf) | Demonstrates why depression benchmark performance can have the wrong explanation. | Peer-reviewed workshop paper; verified |
| 14 | [Larsen et al., Sonde prospective study](https://www.frontiersin.org/journals/psychiatry/articles/10.3389/fpsyt.2024.1342835/full) | Offers a close voice-journaling precedent, with important questionnaire-window and cohort limitations. | Peer-reviewed; methods/results checked; company-affiliated authors |
| 15 | [Karlin et al., Ellipsis real-world study](https://pmc.ncbi.nlm.nih.gov/articles/PMC12223686/) | Shows a blinded real-world evaluation while illustrating that useful discrimination still leaves substantial individual error. | Peer-reviewed; article/results checked; company-affiliated authors |

**Consolidated verdict**

**Sound-with-reservations.** Continue developing transcript-independent acoustic measurement. Do not yet describe its outputs as validated behavioral trends, mood indicators, or “measurement-grade” results.

The three changes that would most strengthen it are:

1. **Build an independently annotated real-speech validation set and predefined acceptance tests for each metric**, including difficult speech, interruptions, and rejected regions.
2. **Establish within-person repeatability and detectable change under a controlled recording/task protocol**, alongside separately analyzed free reflections.
3. **Define a strict claim boundary:** recording-level acoustics first; personal speech trends only after longitudinal validation; psychological interpretation only after separate construct validation.

---

## Part B — prediction vs measurement: ChatGPT self-correction (verbatim)

**My wording was too broad.** The evidence supports saying that modern models can outperform conventional acoustic feature sets on certain prediction tasks. It does **not** establish that they measure speech more accurately, explain behavior better, or outperform Observatory at tracking one person.

Here is the actual basis.

**1. Direct comparisons show improved depression classification**

A 2026 study compared a fine-tuned Whisper model against a classifier using **ComParE handcrafted acoustic features**—a much larger set than pitch, pauses, and rate.

| Evaluation | Handcrafted acoustic model | Fine-tuned Whisper |
|---|---:|---:|
| Development cohort | AUROC **0.84** | **0.95** |
| External validation cohort, 145 participants | AUROC **0.82** | **0.88** |

The study involved Chinese adolescents and clinician-established depression. These results support better **group discrimination in that setting**. They do not establish accurate personal trend measurement or identify which acoustic information caused the improvement. [Yan et al., 2026](https://www.nature.com/articles/s41746-026-03068-5)

A separate adult study compared Whisper embeddings with a classifier using **6,373 openSMILE acoustic-prosodic features**. Whisper embeddings performed better and achieved external-validation AUROC **0.879** in 160 participants. This supplies additional evidence, although the two papers share some researchers and should not be treated as wholly independent research programs. [Lin et al., 2026](https://www.nature.com/articles/s41467-026-74122-9)

**2. For everyday reflections, language sometimes contributes more than richer acoustics**

A study of **3,151 voice diaries from 284 people** compared conventional acoustic features, learned audio representations, and language representations.

Its strongest combined text model achieved **R² = 0.41** for depression questionnaire scores. Acoustic baselines performed worse, and audio embeddings added little incremental value.

That supports looking beyond acoustic descriptors **when predicting depression scores**. It does not demonstrate that advanced acoustic models are universally superior; in this study, the advantage came principally from language. [Emden et al., 2026](https://www.nature.com/articles/s41746-026-02486-9)

**3. Learned representations advance emotional-expression classification**

The **emotion2vec** paper reports improvements over other pretrained and emotion-specialist models on IEMOCAP, with additional evaluations across ten languages.

That establishes progress in **benchmark emotion recognition**. It does not directly compare against your exact feature set, validate experienced mood, or demonstrate measurement-grade F0, pause, or rate estimates. [Ma et al., 2024](https://aclanthology.org/2024.findings-acl.931/)

**What these findings do—and do not—justify**

| Claim | Evidence status |
|---|---|
| Research uses representations much richer than a few named acoustic features | **Supported** |
| Those approaches can improve certain clinical or emotion-classification benchmarks | **Supported, within the evaluated settings** |
| They necessarily measure pitch, pauses, or speech rate more accurately | **Not established by these studies** |
| They reliably detect meaningful changes within one individual | **Not established by these studies** |
| Observatory’s interpretable measurements are scientifically obsolete | **Unsupported** |

The defensible replacement for my statement is:

**“The predictive-research frontier includes learned speech representations and language models that outperform conventional acoustic baselines on some tasks. Their superiority for accurate, interpretable, within-person behavioral measurement remains unproven.”**

I conflated advancement in **prediction** with advancement in **measurement**. That distinction matters directly to your project.

---

## Part C — frontier supplement (verbatim)

**The frontier is substantially beyond pitch, pauses, and speech rate—but much less reliable at understanding someone's internal state than demonstrations suggest.** For Observatory, the most relevant advances are learned speech representations, combining language with acoustics, and repeated measurements in everyday life.

As of **October 24, 2026**, these are publicly documented specialist results. I cannot establish that a private lab has a more capable, clinically validated system hidden from public view.

**1. Models can extract much richer information from sound**

Instead of measuring only named features such as F0, modern speech models produce **embeddings**: numerical representations capturing many patterns in a recording simultaneously.

Specialist models such as **emotion2vec** learn representations aimed at emotional expression. Its published evaluation reported improvements across speech-emotion datasets in ten languages. That is meaningful progress in representation learning; it does not establish accurate measurement of someone's experienced emotions. [Peer-reviewed paper](https://aclanthology.org/2024.findings-acl.931/)

For Observatory, embeddings could eventually complement your interpretable measurements. They would introduce a separate validation obligation: **what changes the representation, and what does that change mean?**

**2. Understanding the words remains surprisingly important**

Two recent studies are especially relevant to your spoken reflections:

| Study | What it found | Practical meaning |
|---|---|---|
| **2026, PNAS Nexus:** 934 participants, 12,285 everyday speech observations | Models predicted self-reported contentment, arousal, and sadness with correlations of approximately **0.37, 0.35, and 0.24**, respectively. Text embeddings carried the strongest emotional signal. | Everyday speech contains useful information, but predictions remain imperfect—and much information comes from what people say. |
| **2026, npj Digital Medicine:** 284 participants, 3,151 smartphone voice diaries | Language embeddings outperformed conventional acoustic features; the combined text model achieved **R² = 0.41** for depression scores. Audio embeddings added little incremental value in that setting. | Removing transcription as a measurement dependency is sensible; permanently excluding language would discard potentially valuable evidence. |

Sources: [Everyday emotional-state study](https://academic.oup.com/pnasnexus/article/5/8/pgag263/8752964), [Smartphone depression study](https://www.nature.com/articles/s41746-026-02486-9).

**Neither result establishes a dependable personal mood meter.** Evaluation on unseen people is different from accurately detecting changes within one particular person. The diary paper explicitly acknowledges that personalized change tracking remains challenging.

These papers should be added near the top of the reading list I gave you.

**3. Depression detection has promising external-validation results**

A 2026 *Nature Communications* study compared learned speech representations with conventional acoustic features. It reported an AUC of **0.932 internally**, falling to **0.879 in an external cohort of 160 people**. [Study](https://www.nature.com/articles/s41467-026-74122-9)

That supports real predictive information in speech. But AUC measures how well a model separates groups across thresholds. It does **not** mean "87.9% accurate," nor demonstrate that the model can reliably explain today's change in your voice.

Other cross-site work remains less reassuring: temporal and spectral measures transferred more consistently than jitter and shimmer, while specificity and recording-condition effects remained problems. [Independent-cohort study](https://link.springer.com/article/10.1186/s12991-026-00691-0)

**4. Fluent audio models can still fail to hear how something was said**

This is one of the more consequential specialist findings.

The **LISTEN benchmark**, published at EACL 2026, deliberately separated the emotional information in words from the information in vocal delivery. Across six tested audio language models, the authors found strong dependence on words; performance approached chance in some conditions requiring acoustic emotion recognition. [Paper](https://aclanthology.org/2026.eacl-long.274/)

An ICML 2026 paper, coauthored by **Mohammad Soleymani**, found a similar problem using **VoxParadox**: models followed what the words implied even when delivery contradicted them. Their targeted adaptation improved one model from **17.4% to 65.2%** on that benchmark. That is a substantial research advance, with substantial remaining error—and the benchmark uses controlled synthesized speech. [Paper](https://proceedings.mlr.press/v306/pang26b.html)

**A system sounding empathic is therefore weak evidence that it measured your voice accurately.**

**5. Where the smaller specialist circle has an advantage**

My inference from this evidence is that the advantage is less about a secret algorithm and more about access to:

- Repeated recordings paired with appropriately timed self-reports and clinical assessments.
- Independent populations, devices, and environments for testing.
- Detailed knowledge of which speech tasks and conditions invalidate particular measurements.
- Evaluation that separates language, vocal delivery, speaker identity, and recording artifacts.

Those assets can matter more than switching to a larger model. Public papers reveal part of that expertise; proprietary datasets and unpublished failures remain inaccessible.

**What this means for Observatory**

Your present acoustic pipeline is **not the frontier of predictive capability**. It is a reasonable foundation for interpretable measurement, provided it passes real-speech validation.

The architecture I would investigate is:

| Layer | Purpose |
|---|---|
| **Validated acoustic measurements** | Establish observable changes with units, coverage, and known error |
| **A separately evaluated speech representation** | Capture richer acoustic patterns that your named features miss |
| **Independent transcription and language analysis** | Preserve meaning and context when transcription is reliable |
| **Personal longitudinal calibration** | Test which changes actually repeat and correspond to your experience |
| **Conservative interpretation** | Report supported observations and uncertainty |

That is my proposed direction, not an already validated recipe. It can preserve on-device processing as a requirement; I have **not** established that a particular combination meets your iPhone's performance constraints.

**The most important frontier question for you is: can a system reliably distinguish a meaningful change in your speech from a change in content, recording conditions, or ordinary variability?** The recent evidence shows progress, but I found no basis to call that problem solved.
