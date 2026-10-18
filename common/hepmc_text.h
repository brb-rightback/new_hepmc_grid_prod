// hepmc_text.h
//
// Shared code for the generator -> "hepmc" converters. Writes the hepevt-like text
// format read by ubcore's HepMCFileGen module (see HepMCFileGen_module.cc):
//
//   <event number> <number of particles>
//   <status> <pdg> <mother1> <mother2> <ccnc> <mode> <px> <py> <pz> <E> <m> <x> <y> <z> <t>   (neutrino)
//   <status> <pdg> 0 0 0 0 <px> <py> <pz> <E> <m> <x> <y> <z> <t>                          (others)
//
// GeV, cm, ns. Status 0 = incoming neutrino (ccnc and mode are stored in the daughter
// slots, the generator event weight in the time slot), 11 = struck nucleon(s),
// 1 = final state tracked by Geant4, 2 = final state not tracked.
//
// Each converter fills a std::vector<Event> and calls write_hepmc_text(), which
// shuffles the events (so the prefix HepMCFileGen consumes is an unbiased random
// subset of an equal-weight sample), draws a vertex and a time in the spill with a
// seeded generator, and writes eventcount.meta.

#ifndef HEPMC_TEXT_H
#define HEPMC_TEXT_H

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <random>
#include <sstream>
#include <string>
#include <vector>

namespace hepmc_text {

// simb::MCNeutrino interaction modes (nusimdata/SimulationBase/MCNeutrino.h)
enum Mode { kUnknown = -1, kQE = 0, kRes = 1, kDIS = 2, kCoh = 3, kElectronScattering = 5,
            kMEC = 10, kCCQEHyperon = 1095 };

struct Particle {
  int pdg = 0;
  int status = 1;
  double px = 0, py = 0, pz = 0, e = 0, m = 0;   // GeV
};

struct Event {
  int ccnc = 0;                   // 0 = CC, 1 = NC
  int mode = kUnknown;
  double weight = 1;
  bool has_vertex = false;        // use x,y,z below instead of sampling one
  double x = 0, y = 0, z = 0;     // cm
  Particle nu;
  std::vector<Particle> initial;  // written with status 11
  std::vector<Particle> final;    // status 1 (tracked) or 2 (not tracked)
};

struct Options {
  std::string output;
  long long seed = -1;
  long max_events = -1;
  bool shuffle = true;
  bool absorber = false;          // rotate momenta into the NuMI absorber direction (KDAR)
  std::string beam = "bnb";       // spill timing preset: bnb | numi
  // vertex box (default: TPC active volume, as in gibuu_to_hepmc3.c)
  double x0 = -1, dx = 257, y0 = -116, dy = 232, z0 = 0, dz = 1037;
  std::vector<std::string> inputs;
};

inline void die(const std::string& prog, const std::string& msg) {
  std::cerr << prog << ": ERROR: " << msg << std::endl;
  std::exit(1);
}

inline std::string common_usage() {
  return "-o OUT -s SEED [-n MAX_EVENTS] [--no-shuffle] [--beam bnb|numi] [--absorber]\n"
         "       [--box x0 dx y0 dy z0 dz]";
}

// Parses the common options. Unknown options are left for the caller (returned).
inline std::vector<std::string> parse_common(int argc, char** argv, Options& o) {
  std::vector<std::string> rest;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto need = [&](int n) { if (i + n >= argc) die(argv[0], "missing value for " + a); };
    if (a == "-o") { need(1); o.output = argv[++i]; }
    else if (a == "-s") { need(1); o.seed = std::atoll(argv[++i]); }
    else if (a == "-n") { need(1); o.max_events = std::atol(argv[++i]); }
    else if (a == "--no-shuffle") o.shuffle = false;
    else if (a == "--absorber") o.absorber = true;
    else if (a == "--beam") { need(1); o.beam = argv[++i]; }
    else if (a == "--box") {
      need(6);
      o.x0 = std::atof(argv[++i]); o.dx = std::atof(argv[++i]);
      o.y0 = std::atof(argv[++i]); o.dy = std::atof(argv[++i]);
      o.z0 = std::atof(argv[++i]); o.dz = std::atof(argv[++i]);
    }
    else rest.push_back(a);
  }
  if (o.beam != "bnb" && o.beam != "numi") die(argv[0], "unknown --beam " + o.beam);
  return rest;
}

inline void rotate_to_absorber(Particle& p) {
  static const double R[3][3] = {{ 0.74302418, -0.58403596, 0.3268288 },
                                 {-0.58403596, -0.32735446, 0.74279274},
                                 {-0.3268288,  -0.74279274, -0.58433029}};
  double x = p.px, y = p.py, z = p.pz;
  p.px = x*R[0][0] + y*R[0][1] + z*R[0][2];
  p.py = x*R[1][0] + y*R[1][1] + z*R[1][2];
  p.pz = x*R[2][0] + y*R[2][1] + z*R[2][2];
}

// Returns the number of events written.
inline size_t write_hepmc_text(const char* prog, std::vector<Event>& events, const Options& o) {
  if (o.output.empty() || o.seed < 0) die(prog, "-o and -s are required");
  if (events.empty()) die(prog, "no events to write");

  std::mt19937_64 rng(static_cast<unsigned long long>(o.seed));
  std::uniform_real_distribution<double> u01(0.0, 1.0);
  if (o.shuffle) std::shuffle(events.begin(), events.end(), rng);
  if (o.max_events > 0 && (long)events.size() > o.max_events) events.resize(o.max_events);

  // time of the interaction in the spill [ns]
  const double t0     = (o.beam == "bnb") ? 3125.  : 5627.5;
  const double tsprd  = (o.beam == "bnb") ? 1600.  : 9600.;

  std::ofstream out(o.output);
  if (!out.good()) die(prog, "cannot open output " + o.output);
  out << std::setprecision(10);

  auto line = [&](int status, const Particle& p, int a, int b, int c, int d,
                  double x, double y, double z, double t) {
    out << status << " " << p.pdg << " " << a << " " << b << " " << c << " " << d << " "
        << p.px << " " << p.py << " " << p.pz << " " << p.e << " " << p.m << " "
        << x << " " << y << " " << z << " " << t << "\n";
  };

  for (size_t i = 0; i < events.size(); ++i) {
    Event& ev = events[i];
    double x = ev.x, y = ev.y, z = ev.z;
    double vx = u01(rng) * o.dx + o.x0;   // always draw, so the sequence does not
    double vy = u01(rng) * o.dy + o.y0;   // depend on whether vertices are provided
    double vz = u01(rng) * o.dz + o.z0;
    double t  = u01(rng) * tsprd + t0;
    if (!ev.has_vertex) { x = vx; y = vy; z = vz; }

    if (o.absorber) {
      rotate_to_absorber(ev.nu);
      for (auto& p : ev.initial) rotate_to_absorber(p);
      for (auto& p : ev.final) rotate_to_absorber(p);
    }

    out << i << " " << 1 + ev.initial.size() + ev.final.size() << "\n";
    line(0, ev.nu, -1, 0, ev.ccnc, ev.mode, x, y, z, ev.weight);
    for (const auto& p : ev.initial) line(11, p, 0, 0, 0, 0, x, y, z, t);
    for (const auto& p : ev.final) line(p.status == 1 ? 1 : 2, p, 0, 0, 0, 0, x, y, z, t);
  }
  out.close();
  if (!out) die(prog, "error writing " + o.output);

  std::ofstream meta("eventcount.meta");
  meta << events.size();
  std::cout << events.size() << " events converted to hepmc (" << o.output << ")" << std::endl;
  return events.size();
}

}  // namespace hepmc_text

#endif
