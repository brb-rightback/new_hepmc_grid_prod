// nuwro_to_hepmc.cc
//
// Converts NuWro output trees (treeout) into the text format read by HepMCFileGen.
// Reads the tree in MakeClass mode, so only ROOT is needed (not NuWro's event
// dictionary). Based on prod_hepmc/prod_nuwro/nuwro_to_hepmc.c, using the shared
// writer in common/hepmc_text.h (seeded vertex/time, shuffling, eventcount.meta).
//
// By default the vertex is drawn uniformly in the TPC active box (as for GiBUU);
// --use-vertex takes NuWro's event vertex r instead (geometry mode, cm).
//
// Build:  g++ -O2 -std=c++17 -I../common $(root-config --cflags) -o nuwro_to_hepmc
//             nuwro_to_hepmc.cc $(root-config --libs)          (one line)
// Usage:  nuwro_to_hepmc -o nuwro_input.hepmc -s SEED [--use-vertex] [common options] in.root [...]

#include "hepmc_text.h"

#include "TFile.h"
#include "TTree.h"

using namespace hepmc_text;

static const char* PROG = "nuwro_to_hepmc";
static const int kMax = 200;

static void read_file(const std::string& fname, bool use_vertex, std::vector<Event>& events) {
  TFile f(fname.c_str());
  if (f.IsZombie()) die(PROG, "cannot open " + fname);
  TTree* t = dynamic_cast<TTree*>(f.Get("treeout"));
  if (!t) die(PROG, "no treeout in " + fname);

  t->SetMakeClass(1);
  t->SetBranchStatus("*", 0);

  Bool_t flag_cc = 0, flag_nc = 0, flag_qel = 0, flag_res = 0, flag_dis = 0, flag_coh = 0,
         flag_mec = 0, flag_hyp = 0, flag_lep = 0;
  Int_t in_ = 0, post_ = 0;
  Double_t in_t[kMax], in_x[kMax], in_y[kMax], in_z[kMax], in_mass[kMax];
  Int_t in_pdg[kMax];
  Double_t post_t[kMax], post_x[kMax], post_y[kMax], post_z[kMax], post_mass[kMax];
  Int_t post_pdg[kMax];
  Double_t r_x = 0, r_y = 0, r_z = 0, weight = 0;

  auto addr = [&](const char* name, void* a, bool required = true) {
    if (!t->GetBranch(name)) {
      if (required) die(PROG, std::string("branch ") + name + " missing in " + fname);
      return;
    }
    t->SetBranchStatus(name, 1);
    t->SetBranchAddress(name, a);
  };
  addr("flag.cc", &flag_cc);   addr("flag.nc", &flag_nc);
  addr("flag.qel", &flag_qel); addr("flag.res", &flag_res); addr("flag.dis", &flag_dis);
  addr("flag.coh", &flag_coh); addr("flag.mec", &flag_mec); addr("flag.hyp", &flag_hyp);
  addr("flag.lep", &flag_lep, false);
  addr("in", &in_);     addr("in.t", in_t);   addr("in.x", in_x);   addr("in.y", in_y);
  addr("in.z", in_z);   addr("in._mass", in_mass);   addr("in.pdg", in_pdg);
  addr("post", &post_); addr("post.t", post_t); addr("post.x", post_x); addr("post.y", post_y);
  addr("post.z", post_z); addr("post._mass", post_mass); addr("post.pdg", post_pdg);
  addr("r.x", &r_x); addr("r.y", &r_y); addr("r.z", &r_z);
  addr("weight", &weight);

  const Long64_t n = t->GetEntries();
  if (n <= 0) die(PROG, "no events in " + fname);
  for (Long64_t i = 0; i < n; ++i) {
    if (t->GetEntry(i) <= 0) die(PROG, "cannot read entry " + std::to_string(i) + " of " + fname);
    if (in_ < 1 || in_ > kMax || post_ < 1 || post_ > kMax)
      die(PROG, "entry " + std::to_string(i) + ": bad particle counts in=" + std::to_string(in_) +
                " post=" + std::to_string(post_));

    Event ev;
    ev.ccnc = flag_nc ? 1 : 0;
    if (flag_cc == flag_nc) die(PROG, "entry " + std::to_string(i) + ": flag.cc == flag.nc");
    ev.mode = kUnknown;
    if (flag_qel) ev.mode = kQE;
    if (flag_res) ev.mode = kRes;
    if (flag_dis) ev.mode = kDIS;
    if (flag_coh) ev.mode = kCoh;
    if (flag_mec) ev.mode = kMEC;
    if (flag_hyp) ev.mode = kCCQEHyperon;
    if (flag_lep) ev.mode = kElectronScattering;
    ev.weight = weight;
    if (use_vertex) { ev.has_vertex = true; ev.x = r_x; ev.y = r_y; ev.z = r_z; }

    auto mk = [](int pdg, double px, double py, double pz, double e, double m) {
      Particle p;
      p.pdg = pdg;
      p.px = px / 1000.; p.py = py / 1000.; p.pz = pz / 1000.; p.e = e / 1000.;   // MeV -> GeV
      p.m = (pdg == 12 || pdg == 14 || pdg == 16 || pdg == -12 || pdg == -14 || pdg == -16 || pdg == 22)
                ? 0.0 : m / 1000.;
      return p;
    };
    ev.nu = mk(in_pdg[0], in_x[0], in_y[0], in_z[0], in_t[0], in_mass[0]);
    int apdg = std::abs(ev.nu.pdg);
    if (apdg != 12 && apdg != 14 && apdg != 16)
      die(PROG, "entry " + std::to_string(i) + ": first incoming particle is " + std::to_string(ev.nu.pdg));
    for (int j = 1; j < in_; ++j)
      ev.initial.push_back(mk(in_pdg[j], in_x[j], in_y[j], in_z[j], in_t[j], in_mass[j]));
    for (int j = 0; j < post_; ++j)
      ev.final.push_back(mk(post_pdg[j], post_x[j], post_y[j], post_z[j], post_t[j], post_mass[j]));
    events.push_back(ev);
  }
  std::cout << "Read " << n << " events from " << fname << std::endl;
}

int main(int argc, char** argv) {
  Options o;
  bool use_vertex = false;
  std::vector<std::string> rest = parse_common(argc, argv, o);
  for (const auto& a : rest) {
    if (a == "--use-vertex") use_vertex = true;
    else if (!a.empty() && a[0] == '-') die(PROG, "unknown option " + a);
    else o.inputs.push_back(a);
  }
  if (o.inputs.empty() || o.output.empty() || o.seed < 0)
    die(PROG, std::string("usage: nuwro_to_hepmc [--use-vertex] ") + common_usage() + " in.root [...]");

  std::vector<Event> events;
  for (const auto& f : o.inputs) read_file(f, use_vertex, events);

  long n_unknown = 0;
  for (const auto& ev : events) if (ev.mode == kUnknown) n_unknown++;
  if (n_unknown > 0) std::cout << "WARNING: " << n_unknown << " events with no recognised NuWro flag (mode -1)" << std::endl;

  write_hepmc_text(PROG, events, o);
  return 0;
}
