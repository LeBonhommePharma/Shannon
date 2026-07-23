class Shannon < Formula
  desc "Physics-grounded LLM safety: Shannon entropy collapse detection (shannon-agent)"
  homepage "https://github.com/LeBonhommePharma/Shannon"
  license "Apache-2.0"

  # Stable installs require a tagged GitHub release (vX.Y.Z). Until then, use --HEAD.
  # After tagging, uncomment and fill sha256 (see scripts/update_homebrew_artifacts.sh):
  # url "https://github.com/LeBonhommePharma/Shannon/archive/refs/tags/v2.0.0.tar.gz"
  # sha256 "REPLACE_WITH_TARBALL_SHA256"
  # version "2.0.0"

  head "https://github.com/LeBonhommePharma/Shannon.git", branch: "main"

  livecheck do
    url :homepage
    regex(%r{href=.*?/tag/v?(\d+(?:\.\d+)+)["' >]}i)
  end

  # Optional Metal GPU path (macOS only). Off by default — needs Xcode Metal toolchain.
  option "with-metal", "Build with Metal GPU acceleration (macOS; needs Metal toolchain)"

  depends_on "cmake" => :build
  depends_on "ninja" => :build
  depends_on "libomp"

  fails_with gcc: "10" # C++20 required (gcc ≥ 11 / AppleClang ≥ 13)

  def install
    metal = if OS.mac? && build.with?("metal")
      "ON"
    else
      "OFF"
    end

    args = %W[
      -GNinja
      -DCMAKE_BUILD_TYPE=Release
      -DSHANNON_BUILD_TESTS=OFF
      -DSHANNON_BUILD_PYTHON=OFF
      -DSHANNON_BUILD_AGENT=ON
      -DSHANNON_USE_OPENMP=ON
      -DSHANNON_USE_CUDA=OFF
      -DSHANNON_USE_METAL=#{metal}
      -DSHANNON_USE_ROCM=OFF
      -DSHANNON_USE_EIGEN=OFF
    ]

    # Homebrew's AppleClang does not ship libomp; wire LLVM OpenMP explicitly.
    if OS.mac?
      libomp = formula_opt_prefix("libomp")
      ENV.append "CPPFLAGS", "-I#{libomp}/include"
      ENV.append "LDFLAGS", "-L#{libomp}/lib -lomp"
      args += %W[
        -DOpenMP_C_FLAGS=-Xpreprocessor\ -fopenmp\ -I#{libomp}/include
        -DOpenMP_C_LIB_NAMES=omp
        -DOpenMP_CXX_FLAGS=-Xpreprocessor\ -fopenmp\ -I#{libomp}/include
        -DOpenMP_CXX_LIB_NAMES=omp
        -DOpenMP_omp_LIBRARY=#{libomp}/lib/libomp.dylib
      ]
    end

    system "cmake", "-S", ".", "-B", "build", *std_cmake_args, *args
    system "cmake", "--build", "build", "--parallel"
    system "cmake", "--install", "build"

    # Hard fallback if install(TARGETS) did not place the binary (prefix layout quirks).
    bin.install "build/shannon-agent" if (buildpath/"build/shannon-agent").exist? && !(bin/"shannon-agent").exist?

    odie "shannon-agent was not installed into #{bin}" unless (bin/"shannon-agent").exist?

    doc.install "README.md", "LICENSE", "CHANGELOG.md" if (buildpath/"README.md").exist?
  end

  def caveats
    <<~EOS
      This formula installs the native `shannon-agent` CLI only (C++ entropy referee).

      Python package (separate):
        pip install "git+https://github.com/LeBonhommePharma/Shannon.git"
        # or after PyPI: pip install shannon-entropy
        shannon-monitor --help

      macOS Pill app (separate cask):
        brew trust --cask lebonhommepharma/shannon/shannon-pill
        brew install --cask lebonhommepharma/shannon/shannon-pill

      Install path (Homebrew 6+ requires a real tap; raw URL installs are rejected):
        brew tap lebonhommepharma/shannon https://github.com/LeBonhommePharma/Shannon
        brew trust --formula lebonhommepharma/shannon/shannon
        brew install --HEAD lebonhommepharma/shannon/shannon

      Default build: CPU + OpenMP (portable). Formula head tracks main only.

      Metal GPU (macOS + Xcode Metal toolchain):
        brew reinstall --build-from-source --HEAD --with-metal lebonhommepharma/shannon/shannon

      Example:
        cat token_stream.jsonl | shannon-agent --window 8 --threshold -3.2
        shannon-agent --help
    EOS
  end

  test do
    assert_path_exists bin/"shannon-agent"
    assert_predicate bin/"shannon-agent", :executable?

    # Help is written to stderr (CLI convention).
    help = shell_output("#{bin}/shannon-agent --help 2>&1")
    assert_match "shannon-agent", help
    assert_match(/collapse/i, help)
    assert_match(/threshold/i, help)

    # Empty / high-entropy stream → no collapse (exit 0).
    high = Array.new(8) { '{"logits":[0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0]}' }.join("\n") + "\n"
    pipe_output("#{bin}/shannon-agent --quiet --handrail log --sustained log --window 4 --threshold -3.2", high, 0)

    # Baseline high-entropy then peaked collapse → exit 1.
    lines = []
    6.times { lines << '{"logits":[0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0]}' }
    6.times { lines << '{"logits":[0.0,-30.0,-30.0,-30.0,-30.0,-30.0,-30.0,-30.0]}' }
    pipe_output(
      "#{bin}/shannon-agent --quiet --handrail log --sustained log --window 4 --threshold -1.0",
      "#{lines.join("\n")}\n",
      1,
    )
  end
end
