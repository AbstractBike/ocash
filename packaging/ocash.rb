# Homebrew formula para ocash
# Uso: brew install --HEAD AbstractBike/ocash/ocash
# (publicar en tap homebrew-ocash o instalar como --formula path)
class Ocash < Formula
  desc "Shell OCaml interactiva con AI local + Ansible + JIT unikernel"
  homepage "https://github.com/AbstractBike/ocash"
  head "https://github.com/AbstractBike/ocash.git", branch: "main"

  depends_on "ocaml" => :build
  depends_on "opam" => :build
  depends_on "dune" => :build
  depends_on "pkg-config" => :build
  depends_on "libev"
  depends_on "openssl@3"

  def install
    system "opam", "init", "--bare", "--disable-sandboxing", "--no-setup", "-y"
    system "opam", "switch", "create", ".", "ocaml-base-compiler.4.14.1", "-y"

    Dir.chdir("#{buildpath}") do
      system "opam", "install", "-y", "--deps-only", "."
      system "opam", "exec", "--", "dune", "build", "-p", "ocash"
      bin.install "_build/default/bin/main.exe" => "ocash"
      bin.install "_build/default/unikernel/uni.exe" => "ocash-ai-unikernel"
    end
  end

  service do
    name macos: "io.abstractbike.ocash-ai-unikernel", linux: "ocash-ai-unikernel"
    run [opt_bin/"ocash-ai-unikernel"]
    keep_alive true
    log_path var/"log/ocash-ai-unikernel.log"
    error_log_path var/"log/ocash-ai-unikernel.log"
  end

  test do
    assert_match "ocash", shell_output("echo exit | #{bin}/ocash 2>&1", 0)
  end
end
