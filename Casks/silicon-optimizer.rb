cask "silicon-optimizer" do
  version "0.5.0"
  sha256 "8a7e15d365b10b92df80fe8e553ca321926dc535a3fa8eb483685b85dc084189"

  url "https://github.com/OGZamasu/silicon-optimizer/releases/download/v#{version}/Silicon.Optimizer.dmg"
  name "Silicon Optimizer"
  desc "Local AI workbench for Apple Silicon: chat agents, images, voice, video, 3D, and a multi-machine swarm"
  homepage "https://optimize.zamasu.dev"

  livecheck do
    url "https://optimize.zamasu.dev/appcast.xml"
    strategy :sparkle, &:short_version
  end

  # Sparkle handles updates in-app, so Homebrew should not fight it over versions.
  auto_updates true
  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "Silicon Optimizer.app"

  zap trash: [
    "~/Library/Application Support/SiliconOptimizer",
    "~/Library/Preferences/dev.siliconoptimizer.app.plist",
    "~/Library/Caches/dev.siliconoptimizer.app",
  ]

  caveats <<~EOS
    Silicon Optimizer releases must pass Gatekeeper. Do not bypass a warning;
    download the current release again and report the failure to the project.

    Chat and language models work out of the box — the llama.cpp engine and
    Node.js runtime ship inside the app. Optional extras (image generation,
    a Windows render node) are described at https://optimize.zamasu.dev
  EOS
end
