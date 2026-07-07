import React, { useState } from "react";
import {
  Plane, Hotel, Utensils, Camera, Plus, ChevronLeft, Check, Users,
  Crown, Eye, Pencil, Link2, Mail, Baby, Luggage, Filter, X, Shirt,
  Plug, FileText, Sparkles,
} from "lucide-react";

// ── tokens (shared with the core-screens prototype) ─────────────
const C = {
  ink: "#1A1B2E", indigo: "#2D2F52", slate: "#6B6E8F", mist: "#EEEDF4",
  paper: "#FBFAF7", amber: "#E8955A", amberSoft: "#FBEADB",
  sky: "#5B7DB1", skySoft: "#E3EAF3", moss: "#6E9E7E", mossSoft: "#E3EEE6",
  plum: "#8B6B9E", plumSoft: "#EDE5F1",
};
const FONT = "'Sofia Sans', -apple-system, system-ui, sans-serif";
const DISPLAY = "'Fraunces', Georgia, serif";
const CATS = {
  flight: { icon: Plane, fg: C.sky, bg: C.skySoft },
  hotel: { icon: Hotel, fg: C.amber, bg: C.amberSoft },
  activity: { icon: Camera, fg: C.moss, bg: C.mossSoft },
  food: { icon: Utensils, fg: C.plum, bg: C.plumSoft },
};
const GRAD = "linear-gradient(135deg, #E8955A 0%, #C96B5B 55%, #2D2F52 100%)";

// family members
const FAM = [
  { id: "n", name: "Naveen", initial: "N", color: "#E8955A", role: "Organizer" },
  { id: "p", name: "Priya", initial: "P", color: "#6E9E7E", role: "Companion" },
  { id: "a", name: "Aarav (12)", initial: "A", color: "#5B7DB1", role: "Companion" },
  { id: "m", name: "Meera (7)", initial: "M", color: "#8B6B9E", role: "Viewer" },
  { id: "g", name: "Grandma", initial: "G", color: "#B58B5B", role: "Viewer" },
];

function Phone({ children }) {
  return (
    <div style={{
      width: 390, height: 844, background: C.paper, borderRadius: 44,
      border: `1px solid ${C.mist}`, position: "relative", overflow: "hidden",
      boxShadow: "0 40px 80px -20px rgba(26,27,46,0.35), 0 0 0 11px #101019, 0 0 0 12px #2a2b3d",
      fontFamily: FONT,
    }}>
      <div style={{
        position: "absolute", top: 0, left: 0, right: 0, height: 54, display: "flex",
        alignItems: "flex-end", justifyContent: "space-between", padding: "0 30px 8px",
        fontSize: 13, fontWeight: 600, color: C.ink, zIndex: 20,
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

function Header({ title, onBack, right }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 14, padding: "10px 20px 14px",
      borderBottom: `1px solid ${C.mist}`, flexShrink: 0 }}>
      <button onClick={onBack} style={{ width: 38, height: 38, borderRadius: 19,
        border: `1px solid ${C.mist}`, background: "#fff", color: C.ink, display: "grid",
        placeItems: "center", cursor: "pointer" }}>
        <ChevronLeft size={20} />
      </button>
      <div style={{ fontSize: 17, fontWeight: 700, color: C.ink, flex: 1 }}>{title}</div>
      {right}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Screen A — Role-aware invite flow
// ─────────────────────────────────────────────────────────────
const ROLES = [
  { key: "Organizer", icon: Crown, fg: C.amber, bg: C.amberSoft, desc: "Full control — edit everything, manage people" },
  { key: "Companion", icon: Pencil, fg: C.moss, bg: C.mossSoft, desc: "Add plans, suggest, comment, edit their own items" },
  { key: "Viewer", icon: Eye, fg: C.sky, bg: C.skySoft, desc: "See the itinerary — no editing. Great for kids & grandparents" },
];

function Invite({ onBack }) {
  const [assigned, setAssigned] = useState({ p: "Companion", a: "Companion", m: "Viewer", g: "Viewer" });
  const [picking, setPicking] = useState(null);

  return (
    <div style={{ position: "absolute", inset: 0, paddingTop: 54, display: "flex", flexDirection: "column",
      background: C.paper }}>
      <Header title="Share this trip" onBack={onBack} />

      <div style={{ flex: 1, overflowY: "auto", padding: "20px 22px 40px" }}>
        {/* Shareable link — the no-app path */}
        <div style={{ background: GRAD, borderRadius: 20, padding: 20, color: "#fff", marginBottom: 12 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 10 }}>
            <Link2 size={19} />
            <span style={{ fontWeight: 700, fontSize: 15 }}>Anyone-can-view link</span>
          </div>
          <div style={{ fontSize: 13, opacity: 0.9, lineHeight: 1.5, marginBottom: 14 }}>
            Share a read-only itinerary that opens in any browser — no app, no account.
            Perfect for grandparents.
          </div>
          <div style={{ display: "flex", gap: 8, alignItems: "center", background: "rgba(255,255,255,0.16)",
            borderRadius: 12, padding: "11px 14px", backdropFilter: "blur(8px)" }}>
            <span style={{ flex: 1, fontSize: 13, fontFamily: "monospace", opacity: 0.95 }}>
              tripto.app/lisbon/a7f3
            </span>
            <button style={{ border: "none", background: "#fff", color: C.ink, borderRadius: 8,
              padding: "6px 12px", fontSize: 12.5, fontWeight: 700, cursor: "pointer", fontFamily: FONT }}>
              Copy
            </button>
          </div>
        </div>

        {/* Invite by email */}
        <div style={{ display: "flex", gap: 10, marginBottom: 26 }}>
          <div style={{ flex: 1, display: "flex", alignItems: "center", gap: 10, background: "#fff",
            border: `1px solid ${C.mist}`, borderRadius: 13, padding: "13px 14px" }}>
            <Mail size={17} color={C.slate} />
            <input placeholder="Invite by email" style={{ border: "none", outline: "none", flex: 1,
              fontSize: 14.5, fontFamily: FONT, color: C.ink, background: "transparent" }} />
          </div>
          <button style={{ border: "none", background: C.indigo, color: "#fff", borderRadius: 13,
            padding: "0 18px", fontSize: 14.5, fontWeight: 700, cursor: "pointer", fontFamily: FONT }}>
            Send
          </button>
        </div>

        {/* People on this trip */}
        <div style={{ fontSize: 12, fontWeight: 700, color: C.slate, textTransform: "uppercase",
          letterSpacing: 0.6, marginBottom: 14 }}>On this trip · {FAM.length}</div>

        {FAM.map((m) => {
          const isOrg = m.role === "Organizer";
          const role = isOrg ? "Organizer" : assigned[m.id];
          const roleObj = ROLES.find((r) => r.key === role);
          return (
            <div key={m.id} style={{ display: "flex", alignItems: "center", gap: 13, padding: "11px 0",
              borderBottom: `1px solid ${C.mist}` }}>
              <div style={{ width: 42, height: 42, borderRadius: 21, background: m.color, color: "#fff",
                display: "grid", placeItems: "center", fontWeight: 700, fontSize: 15, flexShrink: 0 }}>
                {m.initial}
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 15, fontWeight: 600, color: C.ink }}>
                  {m.name}{isOrg && <span style={{ color: C.slate, fontWeight: 500 }}> · you</span>}
                </div>
                <div style={{ fontSize: 12.5, color: C.slate }}>
                  {m.id === "g" ? "viewing via link" : m.role === "Organizer" ? "created the trip" : "joined"}
                </div>
              </div>
              <button
                onClick={() => !isOrg && setPicking(picking === m.id ? null : m.id)}
                style={{ display: "flex", alignItems: "center", gap: 6, background: roleObj.bg,
                  border: "none", borderRadius: 999, padding: "7px 12px", cursor: isOrg ? "default" : "pointer",
                  fontFamily: FONT }}>
                <roleObj.icon size={13} color={roleObj.fg} />
                <span style={{ fontSize: 12.5, fontWeight: 700, color: roleObj.fg }}>{role}</span>
              </button>
            </div>
          );
        })}

        {picking && (
          <div style={{ marginTop: 14, background: "#fff", border: `1px solid ${C.mist}`,
            borderRadius: 16, padding: 8, boxShadow: "0 10px 28px -10px rgba(26,27,46,0.25)" }}>
            {ROLES.filter((r) => r.key !== "Organizer").map((r) => (
              <button key={r.key} onClick={() => { setAssigned({ ...assigned, [picking]: r.key }); setPicking(null); }}
                style={{ display: "flex", gap: 12, width: "100%", textAlign: "left", border: "none",
                  background: "transparent", cursor: "pointer", padding: "12px", borderRadius: 12,
                  fontFamily: FONT, alignItems: "flex-start" }}>
                <div style={{ width: 34, height: 34, borderRadius: 10, background: r.bg, display: "grid",
                  placeItems: "center", flexShrink: 0 }}>
                  <r.icon size={17} color={r.fg} />
                </div>
                <div>
                  <div style={{ fontSize: 14, fontWeight: 700, color: C.ink }}>{r.key}</div>
                  <div style={{ fontSize: 12.5, color: C.slate, marginTop: 2, lineHeight: 1.4 }}>{r.desc}</div>
                </div>
              </button>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Screen B — "Just mine" filtered timeline
// ─────────────────────────────────────────────────────────────
const DAY2 = [
  { id: "d", cat: "flight", time: "08:20", title: "TAP TP1234 · to Lisbon", who: ["n", "p", "a", "m"], tag: null },
  { id: "e", cat: "hotel", time: "16:00", title: "Memmo Alfama check-in", who: ["n", "p", "a", "m", "g"], tag: null },
  { id: "f", cat: "activity", time: "17:30", title: "Meera nap / quiet time", who: ["m"], tag: "nap" },
  { id: "g", cat: "food", time: "20:30", title: "Dinner at Ramiro", who: ["n", "p", "a", "m", "g"], tag: "kids menu" },
  { id: "h", cat: "activity", time: "10:00", title: "Oceanário de Lisboa", who: ["n", "p", "a", "m"], tag: "stroller ok" },
  { id: "i", cat: "activity", time: "15:00", title: "Naveen — car rental pickup", who: ["n"], tag: null },
];

function JustMine({ onBack }) {
  const [who, setWho] = useState("all"); // 'all' or member id
  const visible = who === "all" ? DAY2 : DAY2.filter((x) => x.who.includes(who));
  const me = FAM.find((m) => m.id === who);

  return (
    <div style={{ position: "absolute", inset: 0, paddingTop: 54, display: "flex", flexDirection: "column",
      background: C.paper }}>
      <Header title="Lisbon · Itinerary" onBack={onBack} />

      {/* Person filter */}
      <div style={{ padding: "12px 0 12px 22px", borderBottom: `1px solid ${C.mist}`, flexShrink: 0 }}>
        <div style={{ fontSize: 11.5, fontWeight: 700, color: C.slate, textTransform: "uppercase",
          letterSpacing: 0.5, marginBottom: 10, display: "flex", alignItems: "center", gap: 6 }}>
          <Filter size={12} /> Showing plans for
        </div>
        <div style={{ display: "flex", gap: 8, overflowX: "auto", paddingRight: 22, paddingBottom: 2 }}>
          <button onClick={() => setWho("all")} style={{
            display: "flex", alignItems: "center", gap: 7, border: "none", cursor: "pointer",
            borderRadius: 999, padding: "8px 14px", flexShrink: 0, fontFamily: FONT,
            background: who === "all" ? C.indigo : "#fff",
            boxShadow: who === "all" ? "none" : `inset 0 0 0 1px ${C.mist}`,
          }}>
            <Users size={14} color={who === "all" ? "#fff" : C.slate} />
            <span style={{ fontSize: 13, fontWeight: 700, color: who === "all" ? "#fff" : C.slate }}>Everyone</span>
          </button>
          {FAM.map((m) => {
            const on = who === m.id;
            return (
              <button key={m.id} onClick={() => setWho(m.id)} style={{
                display: "flex", alignItems: "center", gap: 7, border: "none", cursor: "pointer",
                borderRadius: 999, padding: "6px 13px 6px 6px", flexShrink: 0, fontFamily: FONT,
                background: on ? m.color : "#fff",
                boxShadow: on ? "none" : `inset 0 0 0 1px ${C.mist}`,
              }}>
                <div style={{ width: 24, height: 24, borderRadius: 12,
                  background: on ? "rgba(255,255,255,0.28)" : m.color, color: "#fff", display: "grid",
                  placeItems: "center", fontSize: 11, fontWeight: 700 }}>{m.initial}</div>
                <span style={{ fontSize: 13, fontWeight: 700, color: on ? "#fff" : C.slate }}>
                  {m.name.split(" ")[0]}
                </span>
              </button>
            );
          })}
        </div>
      </div>

      {/* Context banner when filtered */}
      {who !== "all" && (
        <div style={{ margin: "12px 22px 0", background: C.amberSoft, borderRadius: 12, padding: "10px 14px",
          display: "flex", alignItems: "center", gap: 9, flexShrink: 0 }}>
          <Sparkles size={15} color={C.amber} />
          <span style={{ fontSize: 12.5, color: "#9a5a2a", fontWeight: 600 }}>
            Just {me.name.split(" ")[0]}'s plans — {visible.length} of {DAY2.length} items
          </span>
        </div>
      )}

      {/* Timeline */}
      <div style={{ flex: 1, overflowY: "auto", padding: "14px 22px 40px" }}>
        <div style={{ position: "relative" }}>
          <div style={{ position: "absolute", left: 46, top: 6, bottom: 6, width: 2, background: C.mist }} />
          {visible.map((it) => {
            const cat = CATS[it.cat];
            const Icon = cat.icon;
            return (
              <div key={it.id} style={{ display: "flex", gap: 12, padding: "6px 0", position: "relative" }}>
                <div style={{ width: 40, textAlign: "right", paddingTop: 14, fontSize: 12, fontWeight: 600,
                  color: C.slate, flexShrink: 0 }}>{it.time}</div>
                <div style={{ width: 14, display: "flex", justifyContent: "center", paddingTop: 15,
                  flexShrink: 0, zIndex: 2 }}>
                  <div style={{ width: 12, height: 12, borderRadius: 6, background: "#fff",
                    border: `2.5px solid ${cat.fg}` }} />
                </div>
                <div style={{ flex: 1, background: "#fff", borderRadius: 16, padding: "12px 14px",
                  border: `1px solid ${C.mist}`, boxShadow: "0 2px 8px -4px rgba(26,27,46,0.12)" }}>
                  <div style={{ display: "flex", gap: 12, alignItems: "center" }}>
                    <div style={{ width: 38, height: 38, borderRadius: 11, background: cat.bg, display: "grid",
                      placeItems: "center", flexShrink: 0 }}>
                      <Icon size={18} color={cat.fg} />
                    </div>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ fontSize: 14.5, fontWeight: 600, color: C.ink }}>{it.title}</div>
                      <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 6 }}>
                        {/* who avatars */}
                        <div style={{ display: "flex" }}>
                          {it.who.slice(0, 4).map((wid, i) => {
                            const person = FAM.find((f) => f.id === wid);
                            return (
                              <div key={wid} style={{ width: 20, height: 20, borderRadius: 10,
                                background: person.color, color: "#fff", display: "grid", placeItems: "center",
                                fontSize: 9, fontWeight: 700, border: "1.5px solid #fff", marginLeft: i ? -6 : 0 }}>
                                {person.initial}
                              </div>
                            );
                          })}
                        </div>
                        {it.tag && (
                          <span style={{ display: "flex", alignItems: "center", gap: 4, background: C.mossSoft,
                            borderRadius: 999, padding: "3px 9px", fontSize: 10.5, fontWeight: 700, color: C.moss }}>
                            {it.tag === "nap" && <Baby size={11} />}
                            {it.tag === "stroller ok" && <Baby size={11} />}
                            {it.tag}
                          </span>
                        )}
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Screen C — Shared assignable packing list
// ─────────────────────────────────────────────────────────────
const PACK_INIT = [
  { id: 1, label: "Passports (all 5)", who: "n", cat: "Documents", icon: FileText, done: true },
  { id: 2, label: "Travel insurance printout", who: "n", cat: "Documents", icon: FileText, done: true },
  { id: 3, label: "Meera's car seat", who: "p", cat: "Kids", icon: Baby, done: false },
  { id: 4, label: "Stroller (compact)", who: "p", cat: "Kids", icon: Baby, done: false },
  { id: 5, label: "Snacks & activities for flight", who: "a", cat: "Kids", icon: Baby, done: false },
  { id: 6, label: "Universal power adapters ×3", who: "n", cat: "Shared", icon: Plug, done: false },
  { id: 7, label: "Sunscreen (family size)", who: "p", cat: "Shared", icon: Shirt, done: true },
  { id: 8, label: "First-aid kit", who: "n", cat: "Shared", icon: Plug, done: false },
];

function Packing({ onBack }) {
  const [items, setItems] = useState(PACK_INIT);
  const toggle = (id) => setItems(items.map((x) => x.id === id ? { ...x, done: !x.done } : x));
  const done = items.filter((x) => x.done).length;
  const pct = Math.round((done / items.length) * 100);
  const cats = ["Documents", "Kids", "Shared"];

  return (
    <div style={{ position: "absolute", inset: 0, paddingTop: 54, display: "flex", flexDirection: "column",
      background: C.paper }}>
      <Header title="Packing & to-dos" onBack={onBack}
        right={<button style={{ width: 38, height: 38, borderRadius: 19, border: "none",
          background: C.amber, color: "#fff", display: "grid", placeItems: "center", cursor: "pointer" }}>
          <Plus size={20} />
        </button>} />

      {/* Progress */}
      <div style={{ padding: "16px 22px 14px", borderBottom: `1px solid ${C.mist}`, flexShrink: 0 }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline",
          marginBottom: 10 }}>
          <span style={{ fontFamily: DISPLAY, fontSize: 20, fontWeight: 600, color: C.ink }}>
            {done} of {items.length} packed
          </span>
          <span style={{ fontSize: 13, fontWeight: 700, color: C.amber }}>{pct}%</span>
        </div>
        <div style={{ height: 8, background: C.mist, borderRadius: 4, overflow: "hidden" }}>
          <div style={{ width: `${pct}%`, height: "100%", background: GRAD, borderRadius: 4,
            transition: "width .3s" }} />
        </div>
      </div>

      <div style={{ flex: 1, overflowY: "auto", padding: "6px 22px 40px" }}>
        {cats.map((cat) => {
          const group = items.filter((x) => x.cat === cat);
          return (
            <div key={cat} style={{ marginTop: 20 }}>
              <div style={{ fontSize: 12, fontWeight: 700, color: C.slate, textTransform: "uppercase",
                letterSpacing: 0.6, marginBottom: 10 }}>{cat}</div>
              {group.map((it) => {
                const person = FAM.find((f) => f.id === it.who);
                return (
                  <button key={it.id} onClick={() => toggle(it.id)} style={{
                    display: "flex", alignItems: "center", gap: 13, width: "100%", textAlign: "left",
                    border: `1px solid ${C.mist}`, background: "#fff", borderRadius: 14, padding: "13px 14px",
                    marginBottom: 9, cursor: "pointer", fontFamily: FONT,
                    opacity: it.done ? 0.6 : 1, transition: "opacity .2s",
                  }}>
                    <div style={{ width: 24, height: 24, borderRadius: 8, flexShrink: 0,
                      border: it.done ? "none" : `2px solid ${C.mist}`,
                      background: it.done ? C.moss : "transparent", display: "grid", placeItems: "center" }}>
                      {it.done && <Check size={15} color="#fff" strokeWidth={3} />}
                    </div>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ fontSize: 14.5, fontWeight: 600, color: C.ink,
                        textDecoration: it.done ? "line-through" : "none" }}>{it.label}</div>
                    </div>
                    {/* who's responsible */}
                    <div style={{ display: "flex", alignItems: "center", gap: 6, background: C.paper,
                      borderRadius: 999, padding: "4px 10px 4px 4px" }}>
                      <div style={{ width: 22, height: 22, borderRadius: 11, background: person.color,
                        color: "#fff", display: "grid", placeItems: "center", fontSize: 10, fontWeight: 700 }}>
                        {person.initial}
                      </div>
                      <span style={{ fontSize: 11.5, fontWeight: 600, color: C.slate }}>
                        {person.name.split(" ")[0]}
                      </span>
                    </div>
                  </button>
                );
              })}
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Gallery
// ─────────────────────────────────────────────────────────────
export default function App() {
  const [screen, setScreen] = useState("invite");
  const screens = {
    invite: <Invite onBack={() => {}} />,
    mine: <JustMine onBack={() => {}} />,
    pack: <Packing onBack={() => {}} />,
  };
  const labels = {
    invite: "Role-aware invite", mine: "“Just mine” filter", pack: "Shared packing list",
  };
  const blurbs = {
    invite: "Three roles keep an organizer in control while kids & grandparents view safely. The anyone-can-view link needs no app.",
    mine: "Tap any family member to filter the dense shared timeline down to just their plans. Note the kid-aware tags — nap window, stroller-friendly, kids' menu.",
    pack: "One shared checklist, each item assigned to a person. Grouped by Documents / Kids / Shared, with family progress up top.",
  };

  return (
    <div style={{ minHeight: "100vh", background: "#101019",
      backgroundImage: "radial-gradient(circle at 20% 10%, #1e2036 0%, #101019 55%)",
      padding: "40px 20px 60px", fontFamily: FONT }}>
      <link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,500;9..144,600&family=Sofia+Sans:wght@400;500;600;700&display=swap" rel="stylesheet" />

      <div style={{ maxWidth: 1180, margin: "0 auto", textAlign: "center", marginBottom: 36 }}>
        <div style={{ fontFamily: DISPLAY, fontSize: 32, color: "#fff", fontWeight: 600,
          letterSpacing: -0.5 }}>Tripto — designing for families</div>
        <div style={{ color: "#8a8ca8", fontSize: 15, marginTop: 8, maxWidth: 620, marginLeft: "auto",
          marginRight: "auto", lineHeight: 1.5 }}>
          A family isn't one user — it's an organizer, a co-parent, kids, and low-tech grandparents,
          all with different needs. These three screens flex for each.
        </div>
      </div>

      <div style={{ display: "flex", justifyContent: "center", gap: 10, marginBottom: 30, flexWrap: "wrap" }}>
        {Object.keys(screens).map((k) => (
          <button key={k} onClick={() => setScreen(k)} style={{
            border: "none", cursor: "pointer", borderRadius: 999, padding: "10px 18px", fontSize: 13.5,
            fontWeight: 700, fontFamily: FONT, background: screen === k ? C.amber : "#22243a",
            color: screen === k ? "#fff" : "#8a8ca8", transition: "all .15s",
          }}>{labels[k]}</button>
        ))}
      </div>

      <div style={{ display: "flex", justifyContent: "center", marginBottom: 24 }}>
        <Phone>{screens[screen]}</Phone>
      </div>

      <div style={{ maxWidth: 560, margin: "0 auto", textAlign: "center", color: "#a9abc4",
        fontSize: 14, lineHeight: 1.6, minHeight: 66 }}>
        {blurbs[screen]}
      </div>
    </div>
  );
}
