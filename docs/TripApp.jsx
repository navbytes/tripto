import React, { useState } from "react";
import {
  Plane, Hotel, Utensils, Camera, MapPin, Plus, ChevronLeft,
  Calendar, Clock, Users, Share2, ArrowRight, Ticket, Navigation, Check,
} from "lucide-react";

// ─────────────────────────────────────────────────────────────
// Design tokens
//   Palette: "dusk departure" — deep indigo night sky meets a warm
//   amber boarding-light. Chosen to feel like evening travel, not a
//   corporate booking portal.
// ─────────────────────────────────────────────────────────────
const C = {
  ink: "#1A1B2E",       // near-black indigo, primary text
  indigo: "#2D2F52",    // card ink / headers
  slate: "#6B6E8F",     // secondary text
  mist: "#EEEDF4",      // hairlines / rails
  paper: "#FBFAF7",     // warm paper background
  amber: "#E8955A",     // boarding-light accent (warm clay-amber)
  amberSoft: "#FBEADB", // amber tint fill
  sky: "#5B7DB1",       // flight blue
  skySoft: "#E3EAF3",
  moss: "#6E9E7E",      // activity green
  mossSoft: "#E3EEE6",
  plum: "#8B6B9E",      // dining plum
  plumSoft: "#EDE5F1",
};

const CATS = {
  flight:   { icon: Plane,    fg: C.sky,   bg: C.skySoft },
  hotel:    { icon: Hotel,    fg: C.amber, bg: C.amberSoft },
  activity: { icon: Camera,   fg: C.moss,  bg: C.mossSoft },
  food:     { icon: Utensils, fg: C.plum,  bg: C.plumSoft },
};

const FONT = "'Sofia Sans', -apple-system, system-ui, sans-serif";
const DISPLAY = "'Fraunces', Georgia, serif";

// ─────────────────────────────────────────────────────────────
// Mock data
// ─────────────────────────────────────────────────────────────
const TRIPS = [
  {
    id: 1, city: "Lisbon", country: "Portugal", days: 6, start: "May 14",
    countdown: 12, collaborators: 4, status: "upcoming",
    grad: "linear-gradient(135deg, #E8955A 0%, #C96B5B 55%, #2D2F52 100%)",
  },
  {
    id: 2, city: "Kyoto", country: "Japan", days: 9, start: "Jul 2",
    countdown: 61, collaborators: 2, status: "upcoming",
    grad: "linear-gradient(135deg, #8B6B9E 0%, #5B7DB1 60%, #1A1B2E 100%)",
  },
  {
    id: 3, city: "Reykjavík", country: "Iceland", days: 5, start: "Feb 3",
    countdown: 0, collaborators: 3, status: "past",
    grad: "linear-gradient(135deg, #6E9E7E 0%, #5B7DB1 55%, #2D2F52 100%)",
  },
];

const ITINERARY = {
  "Day 1 · Wed May 14": [
    { id: "a", cat: "flight", time: "08:20", title: "TAP Air Portugal TP1234", sub: "JFK → LIS · Seat 14C", meta: "6h 55m · Terminal 1", ref: "QK7P2M" },
    { id: "b", cat: "hotel", time: "16:00", title: "Memmo Alfama Hotel", sub: "Check-in · 2 nights", meta: "Travessa das Merceeiras 27", ref: "HTL-88213" },
    { id: "c", cat: "food", time: "20:30", title: "Dinner at Ramiro", sub: "Reservation for 4", meta: "Av. Almirante Reis 1", ref: null },
  ],
  "Day 2 · Thu May 15": [
    { id: "d", cat: "activity", time: "10:00", title: "Tram 28 & Alfama walk", sub: "Self-guided", meta: "Start: Martim Moniz", ref: null },
    { id: "e", cat: "activity", time: "14:30", title: "Jerónimos Monastery", sub: "Skip-the-line ticket", meta: "Praça do Império", ref: "TKT-4471" },
    { id: "f", cat: "food", time: "19:00", title: "Time Out Market", sub: "Casual · no booking", meta: "Av. 24 de Julho 49", ref: null },
  ],
};

// ─────────────────────────────────────────────────────────────
// Phone shell
// ─────────────────────────────────────────────────────────────
function Phone({ children }) {
  return (
    <div style={{
      width: 390, height: 844, background: C.paper, borderRadius: 44,
      border: `1px solid ${C.mist}`, position: "relative", overflow: "hidden",
      boxShadow: "0 40px 80px -20px rgba(26,27,46,0.35), 0 0 0 11px #101019, 0 0 0 12px #2a2b3d",
      fontFamily: FONT,
    }}>
      <div style={{
        position: "absolute", top: 0, left: 0, right: 0, height: 54,
        display: "flex", alignItems: "flex-end", justifyContent: "space-between",
        padding: "0 30px 8px", fontSize: 13, fontWeight: 600, color: C.ink, zIndex: 20,
      }}>
        <span>9:41</span>
        <div style={{ width: 120, height: 30, background: "#101019", borderRadius: 20,
          position: "absolute", left: "50%", transform: "translateX(-50%)", top: 12 }} />
        <span style={{ letterSpacing: 1 }}>􀙇 􀛨 􀛭</span>
      </div>
      {children}
    </div>
  );
}

function Segmented({ tabs, active, onChange }) {
  return (
    <div style={{
      display: "flex", background: C.mist, borderRadius: 12, padding: 3, gap: 2,
    }}>
      {tabs.map((t) => (
        <button key={t} onClick={() => onChange(t)} style={{
          flex: 1, border: "none", borderRadius: 10, padding: "7px 0", cursor: "pointer",
          fontFamily: FONT, fontSize: 13, fontWeight: 600,
          background: active === t ? "#fff" : "transparent",
          color: active === t ? C.ink : C.slate,
          boxShadow: active === t ? "0 1px 3px rgba(26,27,46,0.12)" : "none",
          transition: "all .18s",
        }}>{t}</button>
      ))}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Screen 1 — Home / trip list
// ─────────────────────────────────────────────────────────────
function Home({ onOpenTrip }) {
  const [tab, setTab] = useState("Upcoming");
  const list = TRIPS.filter((t) =>
    tab === "Upcoming" ? t.status === "upcoming" : t.status === "past");

  return (
    <div style={{ position: "absolute", inset: 0, paddingTop: 54, display: "flex", flexDirection: "column" }}>
      <div style={{ padding: "18px 22px 14px" }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <div>
            <div style={{ fontSize: 13, color: C.slate, fontWeight: 500 }}>Good evening, Naveen</div>
            <h1 style={{ fontFamily: DISPLAY, fontSize: 30, color: C.ink, margin: "2px 0 0",
              fontWeight: 600, letterSpacing: -0.5 }}>Your trips</h1>
          </div>
          <div style={{ width: 42, height: 42, borderRadius: 21, background: C.indigo,
            color: "#fff", display: "grid", placeItems: "center", fontWeight: 600, fontSize: 15,
            fontFamily: DISPLAY }}>N</div>
        </div>
      </div>

      <div style={{ padding: "0 22px 14px" }}>
        <Segmented tabs={["Upcoming", "Past"]} active={tab} onChange={setTab} />
      </div>

      <div style={{ flex: 1, overflowY: "auto", padding: "2px 22px 120px" }}>
        {list.map((t) => (
          <button key={t.id} onClick={() => onOpenTrip(t)} style={{
            display: "block", width: "100%", textAlign: "left", border: "none", cursor: "pointer",
            borderRadius: 22, overflow: "hidden", marginBottom: 16, padding: 0,
            boxShadow: "0 12px 28px -12px rgba(26,27,46,0.30)", position: "relative", height: 178,
            background: t.grad, fontFamily: FONT,
          }}>
            <div style={{ position: "absolute", inset: 0, padding: 20, display: "flex",
              flexDirection: "column", justifyContent: "space-between", color: "#fff" }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start" }}>
                {t.countdown > 0 ? (
                  <span style={{ background: "rgba(255,255,255,0.22)", backdropFilter: "blur(8px)",
                    padding: "6px 12px", borderRadius: 999, fontSize: 12, fontWeight: 600 }}>
                    in {t.countdown} days
                  </span>
                ) : (
                  <span style={{ background: "rgba(255,255,255,0.18)", padding: "6px 12px",
                    borderRadius: 999, fontSize: 12, fontWeight: 600 }}>Completed</span>
                )}
                <div style={{ display: "flex", marginRight: 2 }}>
                  {Array.from({ length: Math.min(t.collaborators, 3) }).map((_, i) => (
                    <div key={i} style={{ width: 26, height: 26, borderRadius: 13,
                      background: ["#E8955A", "#6E9E7E", "#8B6B9E"][i], border: "2px solid rgba(255,255,255,0.9)",
                      marginLeft: i ? -9 : 0, display: "grid", placeItems: "center",
                      fontSize: 10, fontWeight: 700, color: "#fff" }}>
                      {["A", "M", "K"][i]}
                    </div>
                  ))}
                </div>
              </div>
              <div>
                <div style={{ fontFamily: DISPLAY, fontSize: 30, fontWeight: 600, lineHeight: 1,
                  letterSpacing: -0.5 }}>{t.city}</div>
                <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 8,
                  fontSize: 13, opacity: 0.92 }}>
                  <span style={{ display: "flex", alignItems: "center", gap: 4 }}>
                    <MapPin size={13} /> {t.country}
                  </span>
                  <span style={{ opacity: 0.5 }}>·</span>
                  <span style={{ display: "flex", alignItems: "center", gap: 4 }}>
                    <Calendar size={13} /> {t.start}
                  </span>
                  <span style={{ opacity: 0.5 }}>·</span>
                  <span>{t.days} days</span>
                </div>
              </div>
            </div>
          </button>
        ))}

        <button style={{
          width: "100%", border: `1.5px dashed ${C.mist}`, background: "transparent",
          borderRadius: 18, padding: "16px 0", cursor: "pointer", color: C.slate,
          fontFamily: FONT, fontSize: 14, fontWeight: 600, display: "flex",
          alignItems: "center", justifyContent: "center", gap: 8,
        }}>
          <Plus size={17} /> Plan a new trip
        </button>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Screen 2 — Itinerary timeline
// ─────────────────────────────────────────────────────────────
function Itinerary({ trip, onBack, onOpenItem, onAdd }) {
  return (
    <div style={{ position: "absolute", inset: 0, paddingTop: 54, display: "flex", flexDirection: "column" }}>
      {/* Hero header */}
      <div style={{ height: 150, background: trip.grad, position: "relative", flexShrink: 0 }}>
        <div style={{ position: "absolute", inset: 0, padding: "6px 20px 18px", color: "#fff",
          display: "flex", flexDirection: "column", justifyContent: "space-between" }}>
          <div style={{ display: "flex", justifyContent: "space-between" }}>
            <button onClick={onBack} style={{ width: 38, height: 38, borderRadius: 19, border: "none",
              background: "rgba(255,255,255,0.22)", backdropFilter: "blur(8px)", color: "#fff",
              display: "grid", placeItems: "center", cursor: "pointer" }}>
              <ChevronLeft size={20} />
            </button>
            <button style={{ width: 38, height: 38, borderRadius: 19, border: "none",
              background: "rgba(255,255,255,0.22)", backdropFilter: "blur(8px)", color: "#fff",
              display: "grid", placeItems: "center", cursor: "pointer" }}>
              <Share2 size={17} />
            </button>
          </div>
          <div>
            <div style={{ fontFamily: DISPLAY, fontSize: 30, fontWeight: 600, lineHeight: 1,
              letterSpacing: -0.5 }}>{trip.city}</div>
            <div style={{ fontSize: 13, opacity: 0.92, marginTop: 6, display: "flex", gap: 8 }}>
              <span>{trip.start}</span><span style={{ opacity: 0.5 }}>·</span>
              <span>{trip.days} days</span><span style={{ opacity: 0.5 }}>·</span>
              <span style={{ display: "flex", alignItems: "center", gap: 4 }}>
                <Users size={12} /> {trip.collaborators}
              </span>
            </div>
          </div>
        </div>
      </div>

      {/* Sub-tabs */}
      <div style={{ display: "flex", gap: 24, padding: "14px 22px 0", borderBottom: `1px solid ${C.mist}`,
        flexShrink: 0 }}>
        {["Itinerary", "Bookings", "Map", "$ Split"].map((t, i) => (
          <div key={t} style={{ paddingBottom: 12, fontSize: 14, fontWeight: 600,
            color: i === 0 ? C.ink : C.slate, borderBottom: i === 0 ? `2px solid ${C.amber}` : "2px solid transparent",
            marginBottom: -1, cursor: "pointer" }}>{t}</div>
        ))}
      </div>

      {/* Timeline */}
      <div style={{ flex: 1, overflowY: "auto", padding: "8px 22px 130px" }}>
        {Object.entries(ITINERARY).map(([day, items]) => (
          <div key={day}>
            <div style={{ position: "sticky", top: 0, background: C.paper, paddingTop: 16,
              paddingBottom: 8, zIndex: 5 }}>
              <div style={{ fontSize: 13, fontWeight: 700, color: C.ink, letterSpacing: 0.2 }}>{day}</div>
            </div>
            <div style={{ position: "relative" }}>
              {/* vertical rail */}
              <div style={{ position: "absolute", left: 46, top: 6, bottom: 6, width: 2,
                background: C.mist }} />
              {items.map((it) => {
                const cat = CATS[it.cat];
                const Icon = cat.icon;
                return (
                  <button key={it.id} onClick={() => onOpenItem(it)} style={{
                    display: "flex", gap: 12, width: "100%", textAlign: "left", border: "none",
                    background: "transparent", cursor: "pointer", padding: "6px 0", position: "relative",
                    fontFamily: FONT,
                  }}>
                    <div style={{ width: 40, textAlign: "right", paddingTop: 14, fontSize: 12,
                      fontWeight: 600, color: C.slate, flexShrink: 0 }}>{it.time}</div>
                    <div style={{ width: 14, display: "flex", justifyContent: "center", paddingTop: 15,
                      flexShrink: 0, zIndex: 2 }}>
                      <div style={{ width: 12, height: 12, borderRadius: 6, background: "#fff",
                        border: `2.5px solid ${cat.fg}` }} />
                    </div>
                    <div style={{ flex: 1, background: "#fff", borderRadius: 16, padding: "12px 14px",
                      border: `1px solid ${C.mist}`, boxShadow: "0 2px 8px -4px rgba(26,27,46,0.12)",
                      display: "flex", gap: 12, alignItems: "center" }}>
                      <div style={{ width: 38, height: 38, borderRadius: 11, background: cat.bg,
                        display: "grid", placeItems: "center", flexShrink: 0 }}>
                        <Icon size={18} color={cat.fg} />
                      </div>
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontSize: 14.5, fontWeight: 600, color: C.ink,
                          whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{it.title}</div>
                        <div style={{ fontSize: 12.5, color: C.slate, marginTop: 2 }}>{it.sub}</div>
                      </div>
                      {it.ref && <Ticket size={15} color={C.mist === C.mist ? C.slate : C.slate} />}
                    </div>
                  </button>
                );
              })}
            </div>
          </div>
        ))}
      </div>

      {/* FAB */}
      <button onClick={onAdd} style={{
        position: "absolute", bottom: 30, right: 22, width: 58, height: 58, borderRadius: 29,
        background: C.amber, border: "none", cursor: "pointer", color: "#fff",
        display: "grid", placeItems: "center", boxShadow: "0 10px 24px -6px rgba(232,149,90,0.6)",
      }}>
        <Plus size={26} />
      </button>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Screen 3 — Add to itinerary
// ─────────────────────────────────────────────────────────────
function AddItem({ onBack }) {
  const [cat, setCat] = useState("flight");
  const cats = [
    { key: "flight", label: "Flight" }, { key: "hotel", label: "Stay" },
    { key: "activity", label: "Activity" }, { key: "food", label: "Food" },
  ];
  return (
    <div style={{ position: "absolute", inset: 0, paddingTop: 54, display: "flex", flexDirection: "column",
      background: C.paper }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between",
        padding: "10px 20px 14px", borderBottom: `1px solid ${C.mist}` }}>
        <button onClick={onBack} style={{ border: "none", background: "transparent", cursor: "pointer",
          color: C.slate, fontSize: 15, fontWeight: 600, fontFamily: FONT }}>Cancel</button>
        <div style={{ fontSize: 16, fontWeight: 700, color: C.ink }}>Add to Lisbon</div>
        <button style={{ border: "none", background: "transparent", cursor: "pointer",
          color: C.mist, fontSize: 15, fontWeight: 700, fontFamily: FONT }}>Save</button>
      </div>

      <div style={{ flex: 1, overflowY: "auto", padding: "20px 22px 40px" }}>
        {/* Auto-import nudge */}
        <div style={{ background: C.indigo, borderRadius: 18, padding: 16, marginBottom: 24,
          display: "flex", gap: 13, alignItems: "center" }}>
          <div style={{ width: 40, height: 40, borderRadius: 12, background: "rgba(232,149,90,0.22)",
            display: "grid", placeItems: "center", flexShrink: 0 }}>
            <Plane size={19} color={C.amber} />
          </div>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 13.5, fontWeight: 600, color: "#fff" }}>Forward your confirmation</div>
            <div style={{ fontSize: 12, color: "rgba(255,255,255,0.7)", marginTop: 2 }}>
              plans@tripto.app — we'll build it for you
            </div>
          </div>
          <ArrowRight size={17} color="rgba(255,255,255,0.6)" />
        </div>

        <div style={{ fontSize: 12, fontWeight: 700, color: C.slate, textTransform: "uppercase",
          letterSpacing: 0.6, marginBottom: 12 }}>Or add manually</div>

        {/* Category selector */}
        <div style={{ display: "flex", gap: 8, marginBottom: 24 }}>
          {cats.map((c) => {
            const cc = CATS[c.key];
            const Icon = cc.icon;
            const on = cat === c.key;
            return (
              <button key={c.key} onClick={() => setCat(c.key)} style={{
                flex: 1, border: on ? `1.5px solid ${cc.fg}` : `1.5px solid ${C.mist}`,
                background: on ? cc.bg : "#fff", borderRadius: 14, padding: "12px 0", cursor: "pointer",
                display: "flex", flexDirection: "column", alignItems: "center", gap: 6, fontFamily: FONT,
                transition: "all .15s",
              }}>
                <Icon size={20} color={on ? cc.fg : C.slate} />
                <span style={{ fontSize: 11.5, fontWeight: 600, color: on ? cc.fg : C.slate }}>{c.label}</span>
              </button>
            );
          })}
        </div>

        {/* Contextual form */}
        <Field label="Airline & flight number" placeholder="e.g. TAP TP1234" icon={Plane} />
        <div style={{ display: "flex", gap: 12 }}>
          <div style={{ flex: 1 }}><Field label="From" placeholder="JFK" /></div>
          <div style={{ flex: 1 }}><Field label="To" placeholder="LIS" /></div>
        </div>
        <div style={{ display: "flex", gap: 12 }}>
          <div style={{ flex: 1 }}><Field label="Date" placeholder="May 14" icon={Calendar} /></div>
          <div style={{ flex: 1 }}><Field label="Departs" placeholder="08:20" icon={Clock} /></div>
        </div>
        <Field label="Confirmation code" placeholder="QK7P2M" icon={Ticket} />

        <button style={{
          width: "100%", background: C.amber, border: "none", borderRadius: 15, padding: "16px 0",
          cursor: "pointer", color: "#fff", fontSize: 15.5, fontWeight: 700, fontFamily: FONT,
          marginTop: 12, boxShadow: "0 8px 20px -6px rgba(232,149,90,0.5)",
        }}>Add flight to itinerary</button>
      </div>
    </div>
  );
}

function Field({ label, placeholder, icon: Icon }) {
  return (
    <div style={{ marginBottom: 16 }}>
      <label style={{ fontSize: 12.5, fontWeight: 600, color: C.slate, display: "block",
        marginBottom: 7 }}>{label}</label>
      <div style={{ display: "flex", alignItems: "center", gap: 10, background: "#fff",
        border: `1px solid ${C.mist}`, borderRadius: 13, padding: "13px 14px" }}>
        {Icon && <Icon size={17} color={C.slate} />}
        <input placeholder={placeholder} style={{ border: "none", outline: "none", flex: 1,
          fontSize: 14.5, fontFamily: FONT, color: C.ink, background: "transparent" }} />
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Screen 4 — Booking detail (boarding-pass style)
// ─────────────────────────────────────────────────────────────
function BookingDetail({ item, onBack }) {
  const cat = CATS[item?.cat || "flight"];
  const isFlight = item?.cat === "flight";
  return (
    <div style={{ position: "absolute", inset: 0, paddingTop: 54, display: "flex", flexDirection: "column",
      background: C.paper }}>
      <div style={{ display: "flex", alignItems: "center", gap: 14, padding: "10px 20px 16px" }}>
        <button onClick={onBack} style={{ width: 38, height: 38, borderRadius: 19, border: `1px solid ${C.mist}`,
          background: "#fff", color: C.ink, display: "grid", placeItems: "center", cursor: "pointer" }}>
          <ChevronLeft size={20} />
        </button>
        <div style={{ fontSize: 17, fontWeight: 700, color: C.ink }}>Booking details</div>
      </div>

      <div style={{ flex: 1, overflowY: "auto", padding: "6px 22px 40px" }}>
        {/* Pass card */}
        <div style={{ borderRadius: 24, overflow: "hidden", boxShadow: "0 16px 36px -14px rgba(26,27,46,0.3)",
          marginBottom: 22 }}>
          <div style={{ background: isFlight ? C.grad : C.indigo, padding: 22,
            background: "linear-gradient(135deg, #5B7DB1 0%, #2D2F52 100%)", color: "#fff" }}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center",
              marginBottom: isFlight ? 22 : 8 }}>
              <div style={{ width: 40, height: 40, borderRadius: 12, background: "rgba(255,255,255,0.18)",
                display: "grid", placeItems: "center" }}>
                <cat.icon size={20} color="#fff" />
              </div>
              <span style={{ fontSize: 12, fontWeight: 600, opacity: 0.85 }}>
                {isFlight ? "TAP Air Portugal" : item?.title}
              </span>
            </div>
            {isFlight && (
              <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
                <div>
                  <div style={{ fontFamily: DISPLAY, fontSize: 34, fontWeight: 600, lineHeight: 1 }}>JFK</div>
                  <div style={{ fontSize: 12, opacity: 0.8, marginTop: 4 }}>New York · 08:20</div>
                </div>
                <div style={{ flex: 1, display: "flex", alignItems: "center", padding: "0 14px" }}>
                  <div style={{ flex: 1, height: 1, background: "rgba(255,255,255,0.4)" }} />
                  <Plane size={18} style={{ margin: "0 6px", transform: "rotate(90deg)" }} />
                  <div style={{ flex: 1, height: 1, background: "rgba(255,255,255,0.4)" }} />
                </div>
                <div style={{ textAlign: "right" }}>
                  <div style={{ fontFamily: DISPLAY, fontSize: 34, fontWeight: 600, lineHeight: 1 }}>LIS</div>
                  <div style={{ fontSize: 12, opacity: 0.8, marginTop: 4 }}>Lisbon · 20:15</div>
                </div>
              </div>
            )}
          </div>
          {/* Perforation */}
          <div style={{ background: "#fff", position: "relative", padding: "20px 22px" }}>
            <div style={{ position: "absolute", top: -11, left: -11, width: 22, height: 22,
              borderRadius: 11, background: C.paper }} />
            <div style={{ position: "absolute", top: -11, right: -11, width: 22, height: 22,
              borderRadius: 11, background: C.paper }} />
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 18 }}>
              {(isFlight
                ? [["Passenger", "Naveen K."], ["Seat", "14C"], ["Confirmation", item?.ref || "QK7P2M"], ["Terminal", "1 · Gate 22"]]
                : [["Guest", "Naveen K."], ["Nights", "2"], ["Confirmation", item?.ref || "HTL-88213"], ["Check-in", "16:00"]]
              ).map(([k, v]) => (
                <div key={k}>
                  <div style={{ fontSize: 11, color: C.slate, fontWeight: 600, textTransform: "uppercase",
                    letterSpacing: 0.5 }}>{k}</div>
                  <div style={{ fontSize: 15.5, fontWeight: 600, color: C.ink, marginTop: 3,
                    fontFamily: k === "Confirmation" ? "monospace" : FONT }}>{v}</div>
                </div>
              ))}
            </div>
          </div>
        </div>

        {/* Actions */}
        <div style={{ display: "flex", gap: 12, marginBottom: 22 }}>
          {[[Calendar, "Add to\ncalendar"], [Navigation, "Get\ndirections"], [Share2, "Share\nwith group"]].map(([Icon, label], i) => (
            <button key={i} style={{ flex: 1, background: "#fff", border: `1px solid ${C.mist}`,
              borderRadius: 15, padding: "14px 0", cursor: "pointer", display: "flex",
              flexDirection: "column", alignItems: "center", gap: 7, fontFamily: FONT }}>
              <Icon size={19} color={C.indigo} />
              <span style={{ fontSize: 11, fontWeight: 600, color: C.slate, whiteSpace: "pre-line",
                textAlign: "center", lineHeight: 1.3 }}>{label}</span>
            </button>
          ))}
        </div>

        {/* Notes */}
        <div style={{ background: "#fff", border: `1px solid ${C.mist}`, borderRadius: 16, padding: 16 }}>
          <div style={{ fontSize: 12, fontWeight: 700, color: C.slate, textTransform: "uppercase",
            letterSpacing: 0.5, marginBottom: 8 }}>Trip note</div>
          <div style={{ fontSize: 14, color: C.ink, lineHeight: 1.5 }}>
            Window seat requested. Priority boarding included with fare. Arrive 3h early for
            international departure.
          </div>
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// App — screen router + gallery layout
// ─────────────────────────────────────────────────────────────
export default function App() {
  const [screen, setScreen] = useState("home");
  const [trip, setTrip] = useState(TRIPS[0]);
  const [item, setItem] = useState(ITINERARY["Day 1 · Wed May 14"][0]);

  const screens = {
    home: <Home onOpenTrip={(t) => { setTrip(t); setScreen("itin"); }} />,
    itin: <Itinerary trip={trip} onBack={() => setScreen("home")}
      onOpenItem={(it) => { setItem(it); setScreen("detail"); }}
      onAdd={() => setScreen("add")} />,
    add: <AddItem onBack={() => setScreen("itin")} />,
    detail: <BookingDetail item={item} onBack={() => setScreen("itin")} />,
  };

  const labels = {
    home: "Home · Trip list", itin: "Itinerary timeline",
    add: "Add to itinerary", detail: "Booking detail",
  };

  return (
    <div style={{ minHeight: "100vh", background: "#101019",
      backgroundImage: "radial-gradient(circle at 20% 10%, #1e2036 0%, #101019 55%)",
      padding: "40px 20px 60px", fontFamily: FONT }}>
      <link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,500;9..144,600&family=Sofia+Sans:wght@400;500;600;700&display=swap" rel="stylesheet" />

      <div style={{ maxWidth: 1180, margin: "0 auto", textAlign: "center", marginBottom: 40 }}>
        <div style={{ fontFamily: DISPLAY, fontSize: 34, color: "#fff", fontWeight: 600,
          letterSpacing: -0.5 }}>Tripto — core screens</div>
        <div style={{ color: "#8a8ca8", fontSize: 15, marginTop: 8 }}>
          Tap a trip card to open its itinerary · tap timeline items for booking details · tap ＋ to add
        </div>
      </div>

      {/* Interactive phone */}
      <div style={{ display: "flex", justifyContent: "center", marginBottom: 56 }}>
        <div>
          <Phone>{screens[screen]}</Phone>
          <div style={{ textAlign: "center", marginTop: 18, color: "#8a8ca8", fontSize: 13,
            display: "flex", gap: 8, justifyContent: "center", flexWrap: "wrap" }}>
            {Object.keys(screens).map((k) => (
              <button key={k} onClick={() => setScreen(k)} style={{
                border: "none", cursor: "pointer", borderRadius: 999, padding: "7px 14px",
                fontSize: 12.5, fontWeight: 600, fontFamily: FONT,
                background: screen === k ? C.amber : "#22243a",
                color: screen === k ? "#fff" : "#8a8ca8", transition: "all .15s",
              }}>{labels[k]}</button>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
