# Shannon v2 C++ API Reference

## Headers

| Header | Purpose |
|--------|---------|
| `shannon/types.hpp` | Core types: enums, structs, `Backend`, `HandrailAction`, `CollapseResult` |
| `shannon/config.hpp` | Build-time constants: version, thresholds, physical constants |
| `shannon/entropy.hpp` | Entropy kernel declarations (all `[[nodiscard]] noexcept`) |
| `shannon/unified_dispatch.hpp` | `UnifiedDispatch` singleton: backend selection, hardware report |
| `shannon/hardware_detect.hpp` | `HardwareCapabilities` struct, `detect_hardware()` |
| `shannon/collapse_detector.hpp` | `CollapseDetector`: sliding window, z-score, callbacks |
| `shannon/handrail.hpp` | `HandrailEngine`: escalation, cooldown, actions |
| `shannon/terminal_agent.hpp` | `TerminalAgent`: full pipeline with stream ingestion |
| `shannon/stream_ingest.hpp` | `StdinIngester`, `SocketIngester`, `ShmemIngester` |
| `shannon/turbo_quant.hpp` | `TurboQuant`: Lloyd-Max quantization |

---

## Namespace

All v2 types and functions are in `namespace shannon`. Entropy kernels are in
`namespace shannon::kernels`. Stream ingesters are in `namespace shannon::ingest`.

---

## Core Types (`types.hpp`)

### `Backend`

```cpp
enum class Backend : uint8_t {
    SCALAR = 0, OPENMP = 1, SSE42 = 2, AVX2 = 3,
    AVX512 = 4, NEON = 5, METAL = 6, CUDA = 7, ROCM = 8,
    AUTO = 255
};
```

### `HandrailAction`

```cpp
enum class HandrailAction {
    LOG_ONLY, ALERT, THROTTLE, KILL, COREDUMP, WEBHOOK, CALLBACK
};
```

| Action | Effect |
|--------|--------|
| `LOG_ONLY` | Write to log file / stderr. No cooldown. |
| `ALERT` | Send `SIGUSR1` to `monitored_pid`. |
| `THROTTLE` | Write `"THROTTLE\n"` to `shmem_path`. |
| `KILL` | Send `SIGTERM` to `monitored_pid`. |
| `COREDUMP` | Send `SIGABRT` to `monitored_pid`. |
| `WEBHOOK` | `fork()`+`execvp("curl",...)` POST to `webhook_url`. |
| `CALLBACK` | Reserved for user-defined callback (future). |

### `CollapseResult`

```cpp
struct CollapseResult {
    double entropy;          // H in bits
    double window_mean;      // mean of sliding window
    double window_std;       // population stddev of window
    double delta;            // H - window_mean
    double z_score;          // delta / window_std
    bool   collapsed;        // delta < threshold && window full
    std::size_t token_index; // 0-based token counter
    Backend used_backend;    // backend that computed entropy
};
```

### `HandrailConfig`

```cpp
struct HandrailConfig {
    HandrailAction on_first_collapse    = HandrailAction::ALERT;
    HandrailAction on_sustained_collapse = HandrailAction::KILL;
    int sustained_threshold             = 3;
    double cooldown_seconds             = 5.0;
    std::string log_path                = "/dev/stderr";
    std::string shmem_path;             // for THROTTLE action
    std::string webhook_url;            // for WEBHOOK action
    std::optional<pid_t> monitored_pid; // for ALERT/KILL/COREDUMP
};
```

### `DispatchResult`

```cpp
struct DispatchResult {
    DispatchError error = DispatchError::OK;
    [[nodiscard]] explicit operator bool() const;
};
```

### `DispatchTelemetry`

```cpp
struct DispatchTelemetry {
    Backend backend         = Backend::SCALAR;
    double  wall_time_ms    = 0.0;
    int64_t elements        = 0;
    double  throughput_meps = 0.0;
    std::string summary() const;  // human-readable string
};
```

---

## Entropy Kernels (`entropy.hpp`)

All functions are `[[nodiscard]] noexcept`.

```cpp
namespace shannon::kernels {

// Configurational entropy from unnormalized log-weights (logits)
double configurational_entropy_scalar(const double* w, std::size_t n) noexcept;

// Shannon entropy from probability distribution
double entropy_from_probs_scalar(const double* p, std::size_t n) noexcept;

// Shannon entropy from log-probabilities (must be normalized)
double entropy_from_logprobs_scalar(const double* lp, std::size_t n) noexcept;

// SIMD/GPU variants (conditionally compiled):
// configurational_entropy_omp, configurational_entropy_sse42,
// configurational_entropy_avx2, configurational_entropy_avx512,
// configurational_entropy_neon
// entropy_from_probs_omp, entropy_from_probs_avx2, entropy_from_probs_avx512
// entropy_from_logprobs_omp, entropy_from_logprobs_avx2, entropy_from_logprobs_avx512
}
```

---

## UnifiedDispatch (`unified_dispatch.hpp`)

Thread-safe singleton. Auto-selects best backend based on runtime hardware
detection.

```cpp
namespace shannon::dispatch {

class UnifiedDispatch {
public:
    static UnifiedDispatch& instance();  // Meyers singleton

    void detect() const;                 // thread-safe via std::call_once
    const hw::HardwareCapabilities& capabilities() const;
    std::string hardware_report() const;

    // Backend selection
    void set_override(Backend b) noexcept;
    void clear_override() noexcept;
    Backend current_override() const noexcept;
    bool is_available(Backend b) const;
    std::vector<Backend> available_backends() const;
    static const char* backend_name(Backend b);

    // Compute functions
    DispatchResult compute_configurational_entropy(
        std::span<const double> logits, double& out_entropy);
    DispatchResult compute_entropy_from_probs(
        std::span<const double> probs, double& out_entropy);
    DispatchResult compute_entropy_from_logprobs(
        std::span<const double> logprobs, double& out_entropy);
};

}
```

---

## CollapseDetector (`collapse_detector.hpp`)

Sliding-window entropy tracker. **Not thread-safe** — use from a single thread
or synchronize externally.

```cpp
class CollapseDetector {
public:
    CollapseDetector(std::size_t window_size = 8,
                     double threshold_bits = -3.2);

    // Feed entropy from logits/probs/logprobs
    CollapseResult add_logits(std::span<const double> logits);
    CollapseResult add_logits(const double* data, std::size_t n);
    CollapseResult add_probs(std::span<const double> probs);
    CollapseResult add_logprobs(std::span<const double> logprobs);

    // Feed raw entropy value directly
    CollapseResult push_entropy(double h);

    // Configuration
    void set_callback(CollapseCallback cb);
    void set_window_size(std::size_t size);
    void set_threshold(double threshold_bits);
    void set_max_trace_size(std::size_t max_size);  // 0 = unlimited

    void reset();

    // Accessors
    std::size_t token_count() const;
    const std::vector<double>& entropy_trace() const;
};
```

---

## HandrailEngine (`handrail.hpp`)

Escalation engine with cooldown. `evaluate()` can be called from multiple
threads — counters are `atomic<int>`, cooldown is mutex-protected.

```cpp
class HandrailEngine {
public:
    explicit HandrailEngine(HandrailConfig cfg);

    void evaluate(const CollapseResult& result);
    void reset();

    int total_collapses() const;     // atomic read
    int escalated_actions() const;   // atomic read
};
```

---

## TerminalAgent (`terminal_agent.hpp`)

Full pipeline: ingestion + detection + handrails.

```cpp
struct AgentConfig {
    std::size_t window_size    = 8;
    double threshold_bits      = -3.2;
    StreamMode stream_mode     = StreamMode::STDIN_PIPE;
    InputFormat input_format   = InputFormat::LOGITS;
    std::string jsonl_field    = "logits";
    std::string socket_path;
    std::string shmem_name;
    HandrailConfig handrail;
    bool verbose = true;
    bool quiet   = false;
    std::string log_path = "/dev/stderr";
};

class TerminalAgent {
public:
    explicit TerminalAgent(AgentConfig config);
    int run();  // blocks until stream ends, returns 0=safe, 1=collapse, 2=error

    CollapseResult process_logits(const double* logits, std::size_t n);
    CollapseResult process_logits(std::span<const double> logits);

    void reset();
    void stop();  // safe to call from any thread

    const CollapseDetector& detector() const noexcept;
    const HandrailEngine& handrail() const noexcept;
    std::size_t tokens_processed() const noexcept;
};
```

---

## HardwareCapabilities (`hardware_detect.hpp`)

```cpp
namespace shannon::hw {

struct HardwareCapabilities {
    bool has_sse42 = false, has_avx2 = false, has_avx512 = false;
    bool has_avx512f = false, has_avx512dq = false, has_avx512bw = false;
    bool has_avx512vnni = false, has_fma = false;
    bool has_neon = false;
    bool has_cuda = false, has_rocm = false, has_metal = false;
    bool has_openmp = false, has_eigen = false;

    int cuda_device_count = 0, rocm_device_count = 0;
    int cuda_sm_major = 0, cuda_sm_minor = 0;
    int openmp_max_threads = 1;
    std::size_t cuda_global_mem = 0, rocm_global_mem = 0;
    std::string cuda_device_name, rocm_device_name;
    std::string cuda_arch, rocm_arch;
    std::string metal_gpu_name;

    std::string summary() const;
};

const HardwareCapabilities& detect_hardware();  // cached singleton

}
```

---

## Stream Ingestion (`stream_ingest.hpp`)

```cpp
namespace shannon::ingest {

struct TokenData {
    std::size_t token_index = 0;
    std::vector<double> logits;
    std::vector<double> probs;
    std::vector<double> logprobs;
    InputFormat format = InputFormat::LOGITS;
};

using TokenCallback = std::function<void(const TokenData&)>;

class StdinIngester {
public:
    explicit StdinIngester(std::string field = "logits",
                           InputFormat format = InputFormat::LOGITS);
    bool read_one(TokenCallback cb);
    void read_all(TokenCallback cb);
    bool parse_jsonl_line(std::string_view line, TokenData& out);
};

class SocketIngester {
public:
    explicit SocketIngester(std::filesystem::path socket_path);
    void listen(TokenCallback cb);
    bool read_one(TokenCallback cb, int timeout_ms = 0);
    void stop();
    void close();
};

class ShmemIngester {
public:
    explicit ShmemIngester(std::string name, std::size_t max_tokens = 128000);
    bool open();
    std::span<const double> read_current();
    void poll(TokenCallback cb, int poll_interval_us = 100);
    void stop();
    void close();
};

}
```

---

## TurboQuant (`turbo_quant.hpp`)

```cpp
namespace shannon::quant {

struct Codebook {
    int bits = 4;
    int levels = 16;
    std::vector<double> centroids;
};

struct QuantizedDistribution {
    std::vector<uint8_t> indices;
    const Codebook* codebook = nullptr;
    std::size_t n = 0;
};

Codebook build_codebook(const double* values, std::size_t n, int bits = 4);
QuantizedDistribution quantize(const double* values, std::size_t n,
                                const Codebook& cb);
std::vector<double> dequantize(const QuantizedDistribution& qd);
double quantized_entropy(const double* values, std::size_t n, int bits = 4);

}
```

Bits clamped to `[1, 8]`. NaN/Inf values skipped during codebook construction.
