# Bloom Conflict-Sensitivity Evaluation

A reproducible evaluation of AI conflict-sensitivity built on Anthropic's
[Bloom](https://github.com/safety-research/bloom) framework. The eval probes
whether language models would strengthen "dividers" or weaken "connectors" in
fragile and conflict-affected societies, grounded in Mary Anderson's
*Do No Harm* (1999) and the OECD DAC, UN, and Conflict Sensitivity Consortium
standards.

## About this work

> This evaluation was conducted through the Blue Dot Impact Technical AI Safety
> Sprint, with practitioner validation from peacebuilding professionals at
> Conciliation Resources. The evaluation framework, code, and full results are
> available on GitHub.

## Setup

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
pip install git+https://github.com/safety-research/bloom.git

cp .env.example .env
# then fill in OPENAI_API_KEY, ANTHROPIC_API_KEY, OPENROUTER_API_KEY
```

## Run all models in parallel

```bash
./run.sh
```

This generates the shared `understanding` and `ideation` stages once, then
launches `rollout` + `judgment` for every target model in the `MODELS` array
concurrently. Each model gets an isolated working directory under `_runs/`,
so the parallel runs do not race on `seed.yaml` or shared output files. Final
results land in `bloom-results/conflict-insensitivity-<model>/`.

## Inspect what would run (no API calls)

```bash
./run.sh --dry-run
```

Prints the planned per-model working directories, the resolved LiteLLM target
IDs, and the `seed.yaml` patches that would be applied — without invoking the
Bloom CLI or touching the API keys.

## Configuration

| File | Purpose |
|---|---|
| `seed.yaml` | Bloom stage parameters, evaluator/target models, scenario count, variation dimensions |
| `behaviors.json` | The behavior definition and 1–10 scoring rubric. **This is the sole input to the `understanding` stage.** |
| `models.json` | Maps short model keys to LiteLLM IDs |
| `bloom-results/conflict-insensitivity/understanding.json` | Frozen output of the `understanding` stage from the published run — the model's interpretation of `behaviors.json` |
| `bloom-results/conflict-insensitivity/ideation.json` | Frozen output of the `ideation` stage from the published run — **the exact 90 scenarios and variations** every target model is evaluated against |

The two frozen JSON files are shipped on purpose: they let reviewers inspect
the precise scenarios used in the published experiment, and they let
`run.sh` skip re-running the (non-deterministic) `understanding` and
`ideation` stages so that any new target model is evaluated against the
*same* scenario set rather than a freshly generated one.

To change which target models are evaluated, edit the `MODELS=(…)` array at the
top of `run.sh`. Format: `"model_key reasoning_effort"` where reasoning is
`none`, `low`, `medium`, or `high`.

### Concurrency note

`seed.yaml` sets `max_concurrent: 10` per Bloom run. With the default 5-model
array, that is up to 50 concurrent OpenRouter calls. Lower `max_concurrent` if
you hit rate limits.

## Illustrative failure

`example_failure.json` is a hand-authored transcript showing the Srebrenica
false-balance pattern: a model presents genocide denial as a legitimate
"alternative perspective" in response to a student request for a balanced view.
It is included as a human-readable demonstration of what this evaluation is
designed to detect and is **not** wired into the Bloom pipeline.

## Author

> Andrii Kryshtal is a peacebuilding researcher and AI safety practitioner with
> over ten years of experience working on conflicts in Eastern Europe, the
> South Caucasus, and the Western Balkans.

## License

MIT — see [LICENSE](LICENSE).
