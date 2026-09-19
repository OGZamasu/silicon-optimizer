# Bonsai long-context load defaults

An explicit `load_model` request for 131,072 tokens used to start with settings recommended
for a smaller context and then overwrite only the context length. On a 36 GiB M5 Max, the
resulting Bonsai 2 27B PQ2_0 configuration used FP16 KV cache, batch/ubatch 2048/512, and
the Prism server's default four slots. A sustained test run reached elevated memory
pressure and added 2.23 GB of swap.

Automatically generated settings for Prism ternary models now use the following defaults
at 131,072 tokens or more on Macs with 36 GiB memory or less:

| Setting | Default |
|---|---|
| Context | Preserve the requested token count |
| KV cache | Q8_0 for K and V |
| Concurrent sequences | One |
| Logical batch | At most 512 |
| Micro-batch | At most 128 |

The policy is applied after a control request's context override is validated, and before
automatic recommendations are evaluated. It applies to both PTQ1_0 and PQ2_0 based on
their required Prism runtime, rather than a model's display name. Existing more compact
cache settings and smaller batches are retained. Shorter contexts, larger Macs, and
ordinary GGUF/MLX quantizations retain their existing policy.

Explicit Advanced configurations and saved presets are still used as supplied. Extra
runtime arguments remain available to override the number of slots. Older saved
configurations without `parallelSequences` decode with the runtime's existing default.
One slot trades concurrent inference capacity for memory headroom, limiting the model to
one simultaneous inference.

## Measurement behind the choice

On the same M5 Max, the complete Q8/one-slot/512/128 test run maintained normal memory
pressure and added no swap. Peak sampled whole-machine memory was 30.98 GB. The prior
FP16 configuration's peak was 35.12 GB. These are whole-configuration observations with
background applications open, not an attribution of savings to any single flag.

The controlled text-only run used Prism build `b10685-7dffb158d`, 131,072 context capacity,
full GPU offload, flash attention, and six CPU threads. It included three uncached
1,024-input/256-output speed trials, one 16,384-input/256-output trial, six objective
problems with reasoning both disabled and enabled, and four-record retrieval from a
15,855-token document. Generation medians were 34.2 tokens/s at short input and 28.9
tokens/s at 16K input. The test server did not load a vision projector.

This is a conservative default, not a guarantee that every workload fits. Full 128K
retrieval and vision workloads were not measured. The hybrid attention memory estimator
remains a separate tracked issue: [#26](https://github.com/OGZamasu/silicon-optimizer/issues/26).

## Reasoning behavior

The six-problem sanity check scored 1/6 with thinking explicitly disabled and 6/6 with
thinking enabled. Bonsai's embedded chat template already enables thinking when the
caller leaves the preference unspecified, which the app's ordinary chat paths do.
This change does not alter thinking defaults or claim to fix model accuracy.

Regression tests cover control requests reaching the generated command with the new
settings, unchanged context validation and expert-slot handling, policy boundaries,
explicit runtime slot arguments, and saved-configuration compatibility.
