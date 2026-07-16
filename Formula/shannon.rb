class Shannon < Formula
  desc "Physics-grounded LLM safety: Shannon entropy collapse detection (shannon-agent)"
  homepage "https://github.com/LeBonhommePharma/Shannon"
  # Head-only until the first GitHub release tag ships a stable tarball.
  # After tagging vX.Y.Z, add:
  #   url "https://github.com/LeBonhommePharma/Shannon/archive/refs/tags/vX.Y.Z.tar.gz"
  #   sha256 "<tarball sha256>"
  #   version "X.Y.Z"
  head "https://github.com/LeBonhommePharma/Shannon.git", branch: "main"
  license "Apache-2.0"

  livecheck do
    url :homepage
    regex(%r{href=.*?/tag/v?(\d+(?:\.\d+)+)["' >]}i)
  end

  # Optional Metal GPU path (macOS only). Off by default — needs Xcode Metal toolchain.
  option "with-metal", "Build with Metal GPU acceleration (macOS; needs Metal toolchain)"

  depends_on "cmake" => :build
  depends_on "ninja" => :build
  depends_on "libomp" if OS.mac?

  def install
    metal = build.with?("metal") ? "ON" : "OFF"

    args = std_cmake_args + %W[
      -GNinja
      -DCMAKE_BUILD_TYPE=Release
      -DSHANNON_BUILD_TESTS=OFF
      -DSHANNON_BUILD_PYTHON=OFF
      -DSHANNON_BUILD_AGENT=ON
      -DSHANNON_USE_OPENMP=ON
      -DSHANNON_USE_CUDA=OFF
      -DSHANNON_USE_METAL=#{metal}
      -DSHANNON_USE_ROCM=OFF
    ]

    if OS.mac?
      libomp = Formula["libomp"].opt_prefix
      args += %W[
        -DOpenMP_C_FLAGS=-Xpreprocessor\ -fopenmp\ -I#{libomp}/include
        -DOpenMP_C_LIB_NAMES=omp
        -DOpenMP_CXX_FLAGS=-Xpreprocessor\ -fopenmp\ -I#{libomp}/include
        -DOpenMP_CXX_LIB_NAMES=omp
        -DOpenMP_omp_LIBRARY=#{libomp}/lib/libomp.dylib
      ]
    end

    system "cmake", "-S", ".", "-B", "build", *args
    system "cmake", "--build", "build", "--parallel"
    system "cmake", "--install", "build"

    # Prefer explicit install of the agent if DESTDIR/prefix layout differs.
    if (buildpath/"build/shannon-agent").exist? && !(bin/"shannon-agent").exist?
      bin.install "build/shannon-agent"
    end
  end

  def caveats
    <<~EOS
      This formula installs the *native* shannon-agent CLI only.

      It does *not* install the Python analysis package. Those are separate:
        # After the first PyPI release:
        pip install shannon-entropy
        # Or from GitHub:
        pip install "git+https://github.com/LeBonhommePharma/Shannon.git"
        # Then: shannon-monitor --help

      Install / reinstall path (Homebrew 6+ requires a real tap; raw URL installs
      are rejected). The tap is this monorepo — keep the tap checkout on main:
        brew tap lebonhommepharma/shannon https://github.com/LeBonhommePharma/Shannon
        # Prefer formula-scoped trust when HOMEBREW_REQUIRE_TAP_TRUST is set
        # (https://docs.brew.sh/Tap-Trust). Do not use HOMEBREW_NO_REQUIRE_TAP_TRUST.
        brew trust --formula lebonhommepharma/shannon/shannon
        brew install --HEAD lebonhommepharma/shannon/shannon

      Default brew build uses CPU + OpenMP (no Metal/CUDA) and is the portable path.
      Formula head tracks main only (never ephemeral fix/* branches).

      Metal GPU (macOS + Xcode Metal toolchain):
        brew install --HEAD --build-from-source --with-metal lebonhommepharma/shannon/shannon

      Example:
        cat token_stream.jsonl | shannon-agent --window 8 --threshold -3.2
        shannon-agent --help
    EOS
  end

  test do
    assert_path_exists bin/"shannon-agent"
    output = shell_output("#{bin}/shannon-agent --help")
    assert_match "shannon-agent", output
    assert_match "Collapse", output
  end
end
