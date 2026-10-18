// gibuu_to_hepmc.cc
//
// Converts GiBUU NuHepMC output (EventFormat=7, HepMC3 ascii) into the text format
// read by HepMCFileGen. Standalone, no ROOT. Replaces gibuu_to_hepmc3.c:
//  * particles are identified by NuHepMC status code instead of fixed line offsets
//  * every input must end with END_EVENT_LISTING (truncated GiBUU output -> error,
//    instead of looping forever / silently dropping the tail)
//  * a missing or unreadable input is an error (gibuu_to_hepmc3.c had `exit;`)
//  * NC interactions get ccnc=1 for every NC ProcID (351/451/551/552 were missed) and
//    all ProcIDs map to simb modes (401/501/502 used to be written raw)
//  * -w W checks that every event has weight W (equal-weights mode); events with
//    non-positive weight are always an error
//  * seeded vertex/time, shuffled output (see common/hepmc_text.h)
//
// Build:  g++ -O2 -std=c++11 -I../common -o gibuu_to_hepmc gibuu_to_hepmc.cc
// Usage:  gibuu_to_hepmc -o nuwro_input.hepmc -s SEED [-w W] [common options] in.hepmc3 [...]

#include "hepmc_text.h"

using namespace hepmc_text;

static const char* PROG = "gibuu_to_hepmc";

// GiBUU NuHepMC ProcIDs (see the NuHepMC.ProcessInfo header of the output):
//   200 CCQE           250 NCQE
//   300 CC 2p2h QE     350 NC 2p2h QE      301/351 2p2h Delta
//   400 CC RES Delta   450 NC RES Delta    401/451 RES other
//   500 CC Bkgd-n      550 NC Bkgd-n       501/551 Bkgd-p   502/552 Bkgd 2pi
//   600 CC DIS         650 NC DIS          0 Unknown
// The non-resonant pion backgrounds are labelled DIS, as GENIE does for non-resonant
// pion production.
static void map_procid(int procid, int& ccnc, int& mode) {
  ccnc = (procid % 100 >= 50) ? 1 : 0;
  switch (procid / 100) {
    case 2: mode = kQE; break;
    case 3: mode = kMEC; break;
    case 4: mode = kRes; break;
    case 5: mode = kDIS; break;
    case 6: mode = kDIS; break;
    default: mode = kUnknown; ccnc = 0; break;
  }
}

static void read_file(const std::string& fname, std::vector<Event>& events, long& n_unknown) {
  std::ifstream in(fname);
  if (!in.good()) die(PROG, "cannot open " + fname);

  std::string line;
  bool have_event = false, seen_end = false;
  Event ev;
  int procid = -1;
  size_t n_before = events.size();

  auto finish = [&]() {
    map_procid(procid, ev.ccnc, ev.mode);
    if (ev.mode == kUnknown) n_unknown++;
    events.push_back(ev);
  };

  while (std::getline(in, line)) {
    if (line.empty()) continue;
    std::istringstream ss(line);
    std::string tag;
    ss >> tag;
    if (tag == "E") {
      if (have_event) finish();
      ev = Event();
      procid = -1;
      have_event = true;
    } else if (tag == "W" && have_event) {
      if (!(ss >> ev.weight)) die(PROG, "bad W line in " + fname + ": " + line);
    } else if (tag == "A" && have_event) {
      int id; std::string key;
      ss >> id >> key;
      if (key == "ProcID") ss >> procid;
    } else if (tag == "P" && have_event) {
      int id, mother;
      Particle p;
      if (!(ss >> id >> mother >> p.pdg >> p.px >> p.py >> p.pz >> p.e >> p.m >> p.status))
        die(PROG, "bad P line in " + fname + ": " + line);
      // NuHepMC status: 4 beam, 20 target, 21 struck nucleon, 22 remnant,
      //                 1 final state, 23 not escaped from the nucleus (-> untracked)
      if (p.status == 4) {
        if (ev.nu.pdg != 0) die(PROG, "two beam particles in an event of " + fname);
        ev.nu = p;
      } else if (p.status == 21) {
        ev.initial.push_back(p);
      } else if (p.status == 1 || p.status == 23) {
        if (p.status == 23) p.status = 2;
        ev.final.push_back(p);
      }
    } else if (tag == "HepMC::Asciiv3-END_EVENT_LISTING") {
      if (have_event) finish();
      have_event = false;
      seen_end = true;
      break;
    }
  }
  if (!seen_end) die(PROG, fname + " has no END_EVENT_LISTING (truncated GiBUU output?)");
  std::cout << "Read " << events.size() - n_before << " events from " << fname << std::endl;
}

int main(int argc, char** argv) {
  Options o;
  double expected_w = -1;
  std::vector<std::string> rest = parse_common(argc, argv, o);
  for (size_t i = 0; i < rest.size(); ++i) {
    if (rest[i] == "-w" && i + 1 < rest.size()) expected_w = std::atof(rest[++i].c_str());
    else if (!rest[i].empty() && rest[i][0] == '-') die(PROG, "unknown option " + rest[i]);
    else o.inputs.push_back(rest[i]);
  }
  if (o.inputs.empty() || o.output.empty() || o.seed < 0)
    die(PROG, "usage: gibuu_to_hepmc [-w W] " + common_usage() + " in.hepmc3 [...]");

  std::vector<Event> events;
  long n_unknown = 0;
  for (const auto& f : o.inputs) read_file(f, events, n_unknown);
  if (events.empty()) die(PROG, "no events read");

  for (size_t i = 0; i < events.size(); ++i) {
    const Event& ev = events[i];
    std::string id = "event " + std::to_string(i) + ": ";
    if (ev.nu.pdg == 0) die(PROG, id + "no beam neutrino");
    if (ev.final.empty()) die(PROG, id + "no outgoing particles");
    if (!(ev.weight > 0)) die(PROG, id + "non-positive weight " + std::to_string(ev.weight));
    if (expected_w > 0 && std::fabs(ev.weight / expected_w - 1) > 1e-6) {
      std::ostringstream m;
      m << id << "weight " << ev.weight << " != expected " << expected_w;
      die(PROG, m.str());
    }
  }
  if (n_unknown > 0) std::cout << "WARNING: " << n_unknown << " events with unknown ProcID (mode -1)" << std::endl;

  write_hepmc_text(PROG, events, o);
  return 0;
}
