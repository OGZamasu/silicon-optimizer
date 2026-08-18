cask "silicon-optimizer" do
  version "0.2.1"
  sha256 :no_check

  url "https://github.com/OGZamasu/silicon-optimizer/releases/download/v#{version}/Silicon.Optimizer.dmg"
  name "Silicon Optimizer"
  desc "Menu bar app that plans memory for local LLMs on Apple Silicon"
  homepage "https://optimize.zamasu.dev"

  # Sparkle handles updates in-app, so Homebrew should not fight it over versions.
  auto_updates true
  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Silicon Optimizer.app"

  zap trash: [
    "~/Library/Application Support/SiliconOptimizer",
    "~/Library/Preferences/dev.siliconoptimizer.app.plist",
    "~/Library/Caches/dev.siliconoptimizer.app",
  ]

  caveats <<~EOS
    Silicon Optimizer is signed but not notarized, so macOS may refuse the first launch.
    If that happens:

      xattr -d com.apple.quarantine "/Applications/Silicon Optimizer.app"

    Language models and the harness chat work out of the box — llama.cpp and Node.js ship
    inside the app. Image generation is the one optional extra:

      python3 -m venv ~/.silicon-mlx && ~/.silicon-mlx/bin/pip install mflux
  EOS
end
