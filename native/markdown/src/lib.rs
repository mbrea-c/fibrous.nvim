// Retained renderer for a single Markdown document between host commits.
use mlua::{Error, Lua, LuaString, Result, Table, UserData, UserDataMethods};
use std::ops::Range;

struct Glyph {
    bytes: Range<usize>,
    width: usize,
    style: u32,
    source: u32,
    hit: u32,
}
struct Word {
    glyphs: Range<usize>,
    width: usize,
}
struct Line {
    glyphs: Range<usize>,
    words: Vec<Word>,
}
struct Node {
    slot: usize,
    intrinsic: usize,
    grow: bool,
    kind: Kind,
}
enum Kind {
    Text {
        lines: Vec<Line>,
        wrap: bool,
    },
    Column {
        children: Vec<Node>,
        gap: usize,
        border: Option<usize>,
        center: bool,
    },
    Row {
        children: Vec<Node>,
        gap: usize,
        justify: String,
    },
}
struct Data {
    bytes: Vec<u8>,
    positions: Vec<i32>,
    glyphs: Vec<Glyph>,
}
impl Data {
    fn new() -> Self {
        // Index zero is padding; index one is the continuation of a wide glyph.
        Self {
            bytes: vec![b' '],
            positions: vec![-1],
            glyphs: vec![
                Glyph {
                    bytes: 0..1,
                    width: 1,
                    style: 0,
                    source: 0,
                    hit: 0,
                },
                Glyph {
                    bytes: 1..1,
                    width: 0,
                    style: 0,
                    source: 0,
                    hit: 0,
                },
            ],
        }
    }
    fn glyph(
        &mut self,
        bytes: Range<usize>,
        width: usize,
        style: u32,
        source: u32,
        hit: u32,
    ) -> usize {
        self.glyphs.push(Glyph {
            bytes,
            width,
            style,
            source,
            hit,
        });
        self.glyphs.len() - 1
    }
    fn node(&mut self, input: Table) -> Result<Node> {
        let slot = input.get("slot")?;
        let intrinsic = input.get("intrinsic")?;
        let grow = input.get("grow")?;
        let tag: String = input.get("kind")?;
        let kind = match tag.as_str() {
            "row" | "col" => {
                let mut children = Vec::new();
                for child in input.get::<Table>("children")?.sequence_values::<Table>() {
                    children.push(self.node(child?)?);
                }
                let gap = input.get("gap")?;
                if tag == "row" {
                    Kind::Row {
                        children,
                        gap,
                        justify: input.get("justify")?,
                    }
                } else {
                    let border = if let Some(style) = input.get::<Option<u32>>("border")? {
                        let start = self.bytes.len();
                        self.bytes.extend("│".as_bytes());
                        self.positions.extend([-1; 3]);
                        Some(self.glyph(start..start + 3, 1, style, 0, 0))
                    } else {
                        None
                    };
                    Kind::Column {
                        children,
                        gap,
                        border,
                        center: input.get("center")?,
                    }
                }
            }
            "text" => {
                let text = input.get::<LuaString>("text")?;
                let encoded = input.get::<LuaString>("glyphs")?;
                let positions = input.get::<LuaString>("positions")?;
                let text = text.as_bytes();
                let glyphs = encoded.as_bytes();
                let positions = positions.as_bytes();
                if positions.len() != text.len() * 4 || glyphs.len() % 20 != 0 {
                    return Err(Error::runtime("invalid compiled text"));
                }
                let base = self.bytes.len();
                self.bytes.extend_from_slice(&text);
                self.positions.extend(
                    positions
                        .chunks_exact(4)
                        .map(|v| i32::from_ne_bytes(v.try_into().unwrap())),
                );
                let mut lines = Vec::new();
                let mut first = self.glyphs.len();
                let (mut start, mut word_width, mut words) = (first, 0, Vec::new());
                let mut cursor = 0;
                for tuple in glyphs.chunks_exact(20) {
                    let num =
                        |n: usize| u32::from_ne_bytes(tuple[n * 4..n * 4 + 4].try_into().unwrap());
                    let end = cursor + num(0) as usize;
                    let slice = text
                        .get(cursor..end)
                        .ok_or_else(|| Error::runtime("invalid cluster"))?;
                    let width = num(1) as usize;
                    let index =
                        self.glyph(base + cursor..base + end, width, num(2), num(3), num(4));
                    if slice == b" " || slice == b"\n" {
                        if start < index {
                            words.push(Word {
                                glyphs: start..index,
                                width: word_width,
                            });
                        }
                        start = index + 1;
                        word_width = 0;
                        if slice == b"\n" {
                            lines.push(Line {
                                glyphs: first..index,
                                words: std::mem::take(&mut words),
                            });
                            first = index + 1;
                        }
                    } else {
                        word_width += width
                    }
                    cursor = end;
                }
                if cursor != text.len() {
                    return Err(Error::runtime("incomplete clusters"));
                }
                let end = self.glyphs.len();
                if start < end {
                    words.push(Word {
                        glyphs: start..end,
                        width: word_width,
                    });
                }
                lines.push(Line {
                    glyphs: first..end,
                    words,
                });
                Kind::Text {
                    lines,
                    wrap: input.get("wrap")?,
                }
            }
            _ => return Err(Error::runtime("unsupported node")),
        };
        Ok(Node {
            slot,
            intrinsic,
            grow,
            kind,
        })
    }
}

struct Grid {
    width: usize,
    cells: Vec<usize>,
    boxes: Vec<u8>,
}
impl Grid {
    fn extend(&mut self, rows: usize) {
        let count = rows * self.width;
        if self.cells.len() < count {
            self.cells.resize(count, 0);
        }
    }
    fn put(&mut self, x: usize, y: usize, id: usize, width: usize) {
        if x >= self.width {
            return;
        }
        let index = y * self.width + x;
        self.cells[index] = id;
        let visible_width = width.min(self.width - x);
        for c in &mut self.cells[index + 1..index + visible_width] {
            *c = 1;
        }
    }
}
impl Node {
    fn paint(&self, data: &Data, grid: &mut Grid, x: usize, y: usize, width: usize) -> usize {
        let mut inset = 0;
        let height = match &self.kind {
            Kind::Column {
                children,
                gap,
                border,
                center,
            } => {
                inset = if border.is_some() { 2 } else { 0 };
                let available = width.saturating_sub(inset);
                let mut row = y;
                for (i, child) in children.iter().enumerate() {
                    if i > 0 {
                        row += gap;
                    }
                    let w = if *center {
                        available.min(child.intrinsic)
                    } else {
                        available
                    };
                    let offset = (available - w) / 2;
                    row += child.paint(data, grid, x + inset + offset, row, w);
                }
                if let Some(id) = border {
                    for r in y..row {
                        grid.put(x, r, *id, 1);
                    }
                }
                row - y
            }
            Kind::Row {
                children,
                gap,
                justify,
            } => {
                // Markdown tables use fixed intrinsic column widths. List bodies
                // are the single growing child following a fixed-width marker.
                let fixed: usize = children
                    .iter()
                    .filter(|c| !c.grow)
                    .map(|c| c.intrinsic)
                    .sum();
                let spare = width.saturating_sub(fixed + gap * children.len().saturating_sub(1));
                let mut col = x + match justify.as_str() {
                    "center" => spare / 2,
                    "end" => spare,
                    _ => 0,
                };
                let mut height = 0;
                for child in children {
                    let w = if child.grow { spare } else { child.intrinsic };
                    height = height.max(child.paint(data, grid, col, y, w));
                    col += w + gap;
                }
                height
            }
            Kind::Text { lines, wrap } => {
                let available = width.max(1);
                let mut row = y;
                for line in lines {
                    grid.extend(row + 1);
                    let mut col = 0;
                    if !wrap {
                        for id in line.glyphs.clone() {
                            let w = data.glyphs[id].width;
                            if col + w > width {
                                break;
                            }
                            grid.put(x + col, row, id, w);
                            col += w;
                        }
                    } else {
                        let mut previous_end = 0;
                        for word in &line.words {
                            if col > 0 {
                                if col + 1 + word.width > available {
                                    row += 1;
                                    grid.extend(row + 1);
                                    col = 0;
                                } else {
                                    grid.put(x + col, row, previous_end, 1);
                                    col += 1;
                                }
                            }
                            for id in word.glyphs.clone() {
                                let w = data.glyphs[id].width;
                                if col > 0 && col + w > available {
                                    row += 1;
                                    grid.extend(row + 1);
                                    col = 0;
                                }
                                if col + w <= width {
                                    grid.put(x + col, row, id, w);
                                }
                                col += w;
                            }
                            previous_end = word.glyphs.end;
                        }
                    }
                    row += 1;
                }
                row - y
            }
        };
        pack(
            &mut grid.boxes,
            self.slot,
            &[
                x as u32,
                y as u32,
                width as u32,
                height as u32,
                inset as u32,
            ],
        );
        height
    }
}

#[derive(Default)]
struct Row {
    text: Vec<u8>,
    marks: Vec<[u32; 3]>,
    maps: Vec<[u32; 4]>,
    hits: Vec<[u32; 5]>,
}
impl Row {
    fn from_cells(cells: &[usize], data: &Data) -> Self {
        let mut row = Self {
            text: Vec::with_capacity(cells.len() + 4),
            ..Self::default()
        };
        for (cell, &id) in cells.iter().enumerate() {
            if id == 0 {
                row.text.push(b' ');
                continue;
            }
            if id == 1 {
                continue;
            }
            let glyph = &data.glyphs[id];
            let col = row.text.len() as u32;
            let clipped = glyph.width > cells.len() - cell;
            if clipped {
                row.text.push(b' ');
            } else {
                row.text.extend_from_slice(&data.bytes[glyph.bytes.clone()]);
            }
            let end = row.text.len() as u32;
            if glyph.style != 0 {
                match row.marks.last_mut() {
                    Some(mark) if mark[1] == col && mark[2] == glyph.style => mark[1] = end,
                    _ => row.marks.push([col, end, glyph.style]),
                }
            }
            if clipped {
                continue;
            }
            if glyph.hit != 0 {
                let x = cell as u32;
                let right = x + glyph.width as u32;
                match row.hits.last_mut() {
                    Some(h) if h[1] == x && h[4] == glyph.hit => {
                        h[1] = right;
                        h[3] = end;
                    }
                    _ => row.hits.push([x, right, col, end, glyph.hit]),
                }
            }
            if glyph.source != 0 {
                for (i, &p) in data.positions[glyph.bytes.clone()].iter().enumerate() {
                    if p < 0 {
                        continue;
                    }
                    let pos = col + i as u32;
                    match row.maps.last_mut() {
                        Some(m)
                            if m[1] == pos
                                && m[2] == glyph.source
                                && m[3] + (pos - m[0]) == p as u32 =>
                        {
                            m[1] += 1
                        }
                        _ => row.maps.push([pos, pos + 1, glyph.source, p as u32]),
                    }
                }
            }
        }
        row
    }
    fn looks_like(&self, other: &Self) -> bool {
        self.text == other.text && self.marks == other.marks
    }
}
fn pack(bytes: &mut Vec<u8>, row: usize, span: &[u32]) {
    bytes.extend_from_slice(&(row as u32).to_ne_bytes());
    for &field in span {
        bytes.extend_from_slice(&field.to_ne_bytes());
    }
}
struct Document {
    node: Node,
    data: Data,
    prev: Vec<Row>,
}
impl UserData for Document {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method_mut("resize", |lua, doc, width: usize| {
            if !(1..=16384).contains(&width) {
                return Err(Error::runtime("invalid width"));
            }
            let mut grid = Grid {
                width,
                cells: Vec::new(),
                boxes: Vec::new(),
            };
            doc.node.paint(&doc.data, &mut grid, 0, 0, width);
            let rows: Vec<_> = grid
                .cells
                .chunks_exact(width)
                .map(|r| Row::from_cells(r, &doc.data))
                .collect();
            let head = doc
                .prev
                .iter()
                .zip(&rows)
                .take_while(|(a, b)| a.looks_like(b))
                .count();
            let tail = doc.prev[head..]
                .iter()
                .rev()
                .zip(rows[head..].iter().rev())
                .take_while(|(a, b)| a.looks_like(b))
                .count();
            let old_end = doc.prev.len() - tail;
            let end = rows.len() - tail;
            let lines = lua.create_table_with_capacity(end - head, 0)?;
            let mut hits = Vec::new();
            let (mut marks, mut maps) = (Vec::new(), Vec::new());
            for (i, row) in rows.iter().enumerate() {
                if i >= head && i < end {
                    lines.raw_set(i - head + 1, lua.create_string(&row.text)?)?;
                    for mark in &row.marks {
                        pack(&mut marks, i, mark);
                    }
                }
                for hit in &row.hits {
                    pack(&mut hits, i, hit);
                }
                for m in &row.maps {
                    pack(&mut maps, i, m);
                }
            }
            let output = (
                head,
                old_end,
                lines,
                lua.create_string(marks)?,
                lua.create_string(maps)?,
                lua.create_string(grid.boxes)?,
                lua.create_string(hits)?,
            );
            doc.prev = rows;
            Ok(output)
        });
    }
}
#[mlua::lua_module]
fn fibrous_markdown_native(lua: &Lua) -> Result<Table> {
    let m = lua.create_table()?;
    m.set("abi_version", 1)?;
    m.set(
        "compile",
        lua.create_function(|_, tree: Table| {
            let mut data = Data::new();
            let node = data.node(tree)?;
            Ok(Document {
                node,
                data,
                prev: Vec::new(),
            })
        })?,
    )?;
    Ok(m)
}
