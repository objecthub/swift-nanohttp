//
//  HTMLElements.swift
//  NanoHTML
//
//  Created by Matthias Zenger on 14/10/2026.
//  Copyright © 2026 Matthias Zenger. All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//
//  * Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
//
//  * Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
//  * Neither the name of the copyright holder nor the names of its contributors
//    may be used to endorse or promote products derived from this software without
//    specific prior written permission.
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
//  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
//  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//  DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
//  ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
//  (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
//  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
//  ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
//  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

import Foundation

/// The tags of the element types, which are the ones of HTML. They are only the markers
/// that the element types are built on, see ``HTMLElement``.
public enum HTMLTags {}

// The element types. Elements that were removed from HTML (`center`, `font`, `marquee`,
// ...) have none; ``CustomElement`` writes any other element.
//
// Some names are also names of types in SwiftUI or AppKit (`Button`, `Label`, `Link`, `Form`,
// `Table`, `Menu`, `Section`, `Canvas`): in a file that imports one of these frameworks, write
// the module name, `NanoHTML.Button`.

// MARK: - The document

extension HTMLTags {
  public enum Html: HTMLContainerTag {
    public static let name = "html"
    public static let prefix = "<!DOCTYPE html>"
  }
}

/// The `html` element: the root of a document. It writes the document type (`<!DOCTYPE html>`)
/// before itself.
public typealias Html = HTMLElement<HTMLTags.Html>

// MARK: - Elements with content

extension HTMLTags {
  public enum A: HTMLContainerTag {
    public static let name = "a"
  }
}

/// The `a` element: a link.
public typealias A = HTMLElement<HTMLTags.A>

extension HTMLTags {
  public enum Abbr: HTMLContainerTag {
    public static let name = "abbr"
  }
}

/// The `abbr` element: an abbreviation.
public typealias Abbr = HTMLElement<HTMLTags.Abbr>

extension HTMLTags {
  public enum Address: HTMLContainerTag {
    public static let name = "address"
  }
}

/// The `address` element: contact information.
public typealias Address = HTMLElement<HTMLTags.Address>

extension HTMLTags {
  public enum Article: HTMLContainerTag {
    public static let name = "article"
  }
}

/// The `article` element: a self-contained piece of content.
public typealias Article = HTMLElement<HTMLTags.Article>

extension HTMLTags {
  public enum Aside: HTMLContainerTag {
    public static let name = "aside"
  }
}

/// The `aside` element: content beside the main content.
public typealias Aside = HTMLElement<HTMLTags.Aside>

extension HTMLTags {
  public enum Audio: HTMLContainerTag {
    public static let name = "audio"
  }
}

/// The `audio` element: sound.
public typealias Audio = HTMLElement<HTMLTags.Audio>

extension HTMLTags {
  public enum B: HTMLContainerTag {
    public static let name = "b"
  }
}

/// The `b` element: text that is drawn attention to.
public typealias B = HTMLElement<HTMLTags.B>

extension HTMLTags {
  public enum Bdi: HTMLContainerTag {
    public static let name = "bdi"
  }
}

/// The `bdi` element: text in its own text direction.
public typealias Bdi = HTMLElement<HTMLTags.Bdi>

extension HTMLTags {
  public enum Bdo: HTMLContainerTag {
    public static let name = "bdo"
  }
}

/// The `bdo` element: text with an overridden text direction.
public typealias Bdo = HTMLElement<HTMLTags.Bdo>

extension HTMLTags {
  public enum Blockquote: HTMLContainerTag {
    public static let name = "blockquote"
  }
}

/// The `blockquote` element: a quotation.
public typealias Blockquote = HTMLElement<HTMLTags.Blockquote>

extension HTMLTags {
  public enum Body: HTMLContainerTag {
    public static let name = "body"
  }
}

/// The `body` element: the content of the document.
public typealias Body = HTMLElement<HTMLTags.Body>

extension HTMLTags {
  public enum Button: HTMLContainerTag {
    public static let name = "button"
  }
}

/// The `button` element: a button.
public typealias Button = HTMLElement<HTMLTags.Button>

extension HTMLTags {
  public enum Canvas: HTMLContainerTag {
    public static let name = "canvas"
  }
}

/// The `canvas` element: a canvas for scripts to draw on.
public typealias Canvas = HTMLElement<HTMLTags.Canvas>

extension HTMLTags {
  public enum Caption: HTMLContainerTag {
    public static let name = "caption"
  }
}

/// The `caption` element: the caption of a table.
public typealias Caption = HTMLElement<HTMLTags.Caption>

extension HTMLTags {
  public enum Cite: HTMLContainerTag {
    public static let name = "cite"
  }
}

/// The `cite` element: the title of a work.
public typealias Cite = HTMLElement<HTMLTags.Cite>

extension HTMLTags {
  public enum Code: HTMLContainerTag {
    public static let name = "code"
  }
}

/// The `code` element: computer code.
public typealias Code = HTMLElement<HTMLTags.Code>

extension HTMLTags {
  public enum Colgroup: HTMLContainerTag {
    public static let name = "colgroup"
  }
}

/// The `colgroup` element: a group of table columns.
public typealias Colgroup = HTMLElement<HTMLTags.Colgroup>

extension HTMLTags {
  public enum DataValue: HTMLContainerTag {
    public static let name = "data"
  }
}

/// The `data` element: a value in a machine-readable form (the type is not called `Data`,
/// which is a Foundation type).
public typealias DataValue = HTMLElement<HTMLTags.DataValue>

extension HTMLTags {
  public enum Datalist: HTMLContainerTag {
    public static let name = "datalist"
  }
}

/// The `datalist` element: suggestions for an input.
public typealias Datalist = HTMLElement<HTMLTags.Datalist>

extension HTMLTags {
  public enum Dd: HTMLContainerTag {
    public static let name = "dd"
  }
}

/// The `dd` element: a description of a term.
public typealias Dd = HTMLElement<HTMLTags.Dd>

extension HTMLTags {
  public enum Del: HTMLContainerTag {
    public static let name = "del"
  }
}

/// The `del` element: deleted text.
public typealias Del = HTMLElement<HTMLTags.Del>

extension HTMLTags {
  public enum Details: HTMLContainerTag {
    public static let name = "details"
  }
}

/// The `details` element: a disclosure widget.
public typealias Details = HTMLElement<HTMLTags.Details>

extension HTMLTags {
  public enum Dfn: HTMLContainerTag {
    public static let name = "dfn"
  }
}

/// The `dfn` element: a term that is defined.
public typealias Dfn = HTMLElement<HTMLTags.Dfn>

extension HTMLTags {
  public enum Dialog: HTMLContainerTag {
    public static let name = "dialog"
  }
}

/// The `dialog` element: a dialog.
public typealias Dialog = HTMLElement<HTMLTags.Dialog>

extension HTMLTags {
  public enum Div: HTMLContainerTag {
    public static let name = "div"
  }
}

/// The `div` element: a generic block of content.
public typealias Div = HTMLElement<HTMLTags.Div>

extension HTMLTags {
  public enum Dl: HTMLContainerTag {
    public static let name = "dl"
  }
}

/// The `dl` element: a list of terms and descriptions.
public typealias Dl = HTMLElement<HTMLTags.Dl>

extension HTMLTags {
  public enum Dt: HTMLContainerTag {
    public static let name = "dt"
  }
}

/// The `dt` element: a term.
public typealias Dt = HTMLElement<HTMLTags.Dt>

extension HTMLTags {
  public enum Em: HTMLContainerTag {
    public static let name = "em"
  }
}

/// The `em` element: emphasized text.
public typealias Em = HTMLElement<HTMLTags.Em>

extension HTMLTags {
  public enum Fieldset: HTMLContainerTag {
    public static let name = "fieldset"
  }
}

/// The `fieldset` element: a group of form controls.
public typealias Fieldset = HTMLElement<HTMLTags.Fieldset>

extension HTMLTags {
  public enum Figcaption: HTMLContainerTag {
    public static let name = "figcaption"
  }
}

/// The `figcaption` element: the caption of a figure.
public typealias Figcaption = HTMLElement<HTMLTags.Figcaption>

extension HTMLTags {
  public enum Figure: HTMLContainerTag {
    public static let name = "figure"
  }
}

/// The `figure` element: a figure with an optional caption.
public typealias Figure = HTMLElement<HTMLTags.Figure>

extension HTMLTags {
  public enum Footer: HTMLContainerTag {
    public static let name = "footer"
  }
}

/// The `footer` element: a footer.
public typealias Footer = HTMLElement<HTMLTags.Footer>

extension HTMLTags {
  public enum Form: HTMLContainerTag {
    public static let name = "form"
  }
}

/// The `form` element: a form.
public typealias Form = HTMLElement<HTMLTags.Form>

extension HTMLTags {
  public enum H1: HTMLContainerTag {
    public static let name = "h1"
  }
}

/// The `h1` element: a heading of level 1.
public typealias H1 = HTMLElement<HTMLTags.H1>

extension HTMLTags {
  public enum H2: HTMLContainerTag {
    public static let name = "h2"
  }
}

/// The `h2` element: a heading of level 2.
public typealias H2 = HTMLElement<HTMLTags.H2>

extension HTMLTags {
  public enum H3: HTMLContainerTag {
    public static let name = "h3"
  }
}

/// The `h3` element: a heading of level 3.
public typealias H3 = HTMLElement<HTMLTags.H3>

extension HTMLTags {
  public enum H4: HTMLContainerTag {
    public static let name = "h4"
  }
}

/// The `h4` element: a heading of level 4.
public typealias H4 = HTMLElement<HTMLTags.H4>

extension HTMLTags {
  public enum H5: HTMLContainerTag {
    public static let name = "h5"
  }
}

/// The `h5` element: a heading of level 5.
public typealias H5 = HTMLElement<HTMLTags.H5>

extension HTMLTags {
  public enum H6: HTMLContainerTag {
    public static let name = "h6"
  }
}

/// The `h6` element: a heading of level 6.
public typealias H6 = HTMLElement<HTMLTags.H6>

extension HTMLTags {
  public enum Head: HTMLContainerTag {
    public static let name = "head"
  }
}

/// The `head` element: the metadata of the document.
public typealias Head = HTMLElement<HTMLTags.Head>

extension HTMLTags {
  public enum Header: HTMLContainerTag {
    public static let name = "header"
  }
}

/// The `header` element: a header.
public typealias Header = HTMLElement<HTMLTags.Header>

extension HTMLTags {
  public enum Hgroup: HTMLContainerTag {
    public static let name = "hgroup"
  }
}

/// The `hgroup` element: a heading with its subheadings.
public typealias Hgroup = HTMLElement<HTMLTags.Hgroup>

extension HTMLTags {
  public enum I: HTMLContainerTag {
    public static let name = "i"
  }
}

/// The `i` element: text in an alternate voice.
public typealias I = HTMLElement<HTMLTags.I>

extension HTMLTags {
  public enum Iframe: HTMLContainerTag {
    public static let name = "iframe"
  }
}

/// The `iframe` element: a nested page.
public typealias Iframe = HTMLElement<HTMLTags.Iframe>

extension HTMLTags {
  public enum Ins: HTMLContainerTag {
    public static let name = "ins"
  }
}

/// The `ins` element: inserted text.
public typealias Ins = HTMLElement<HTMLTags.Ins>

extension HTMLTags {
  public enum Kbd: HTMLContainerTag {
    public static let name = "kbd"
  }
}

/// The `kbd` element: keyboard input.
public typealias Kbd = HTMLElement<HTMLTags.Kbd>

extension HTMLTags {
  public enum Label: HTMLContainerTag {
    public static let name = "label"
  }
}

/// The `label` element: the label of a form control.
public typealias Label = HTMLElement<HTMLTags.Label>

extension HTMLTags {
  public enum Legend: HTMLContainerTag {
    public static let name = "legend"
  }
}

/// The `legend` element: the caption of a fieldset.
public typealias Legend = HTMLElement<HTMLTags.Legend>

extension HTMLTags {
  public enum Li: HTMLContainerTag {
    public static let name = "li"
  }
}

/// The `li` element: a list item.
public typealias Li = HTMLElement<HTMLTags.Li>

extension HTMLTags {
  public enum Main: HTMLContainerTag {
    public static let name = "main"
  }
}

/// The `main` element: the main content.
public typealias Main = HTMLElement<HTMLTags.Main>

extension HTMLTags {
  public enum Map: HTMLContainerTag {
    public static let name = "map"
  }
}

/// The `map` element: an image map.
public typealias Map = HTMLElement<HTMLTags.Map>

extension HTMLTags {
  public enum Mark: HTMLContainerTag {
    public static let name = "mark"
  }
}

/// The `mark` element: highlighted text.
public typealias Mark = HTMLElement<HTMLTags.Mark>

extension HTMLTags {
  public enum Menu: HTMLContainerTag {
    public static let name = "menu"
  }
}

/// The `menu` element: a list of commands.
public typealias Menu = HTMLElement<HTMLTags.Menu>

extension HTMLTags {
  public enum Meter: HTMLContainerTag {
    public static let name = "meter"
  }
}

/// The `meter` element: a scalar measurement.
public typealias Meter = HTMLElement<HTMLTags.Meter>

extension HTMLTags {
  public enum Nav: HTMLContainerTag {
    public static let name = "nav"
  }
}

/// The `nav` element: navigation links.
public typealias Nav = HTMLElement<HTMLTags.Nav>

extension HTMLTags {
  public enum Noscript: HTMLContainerTag {
    public static let name = "noscript"
  }
}

/// The `noscript` element: content for browsers without scripts.
public typealias Noscript = HTMLElement<HTMLTags.Noscript>

extension HTMLTags {
  public enum Object: HTMLContainerTag {
    public static let name = "object"
  }
}

/// The `object` element: an embedded object.
public typealias Object = HTMLElement<HTMLTags.Object>

extension HTMLTags {
  public enum Ol: HTMLContainerTag {
    public static let name = "ol"
  }
}

/// The `ol` element: an ordered list.
public typealias Ol = HTMLElement<HTMLTags.Ol>

extension HTMLTags {
  public enum Optgroup: HTMLContainerTag {
    public static let name = "optgroup"
  }
}

/// The `optgroup` element: a group of options.
public typealias Optgroup = HTMLElement<HTMLTags.Optgroup>

extension HTMLTags {
  public enum Option: HTMLContainerTag {
    public static let name = "option"
  }
}

/// The `option` element: an option of a select.
public typealias Option = HTMLElement<HTMLTags.Option>

extension HTMLTags {
  public enum Output: HTMLContainerTag {
    public static let name = "output"
  }
}

/// The `output` element: the result of a calculation.
public typealias Output = HTMLElement<HTMLTags.Output>

extension HTMLTags {
  public enum P: HTMLContainerTag {
    public static let name = "p"
  }
}

/// The `p` element: a paragraph.
public typealias P = HTMLElement<HTMLTags.P>

extension HTMLTags {
  public enum Picture: HTMLContainerTag {
    public static let name = "picture"
  }
}

/// The `picture` element: an image with alternative sources.
public typealias Picture = HTMLElement<HTMLTags.Picture>

extension HTMLTags {
  public enum Pre: HTMLContainerTag {
    public static let name = "pre"
  }
}

/// The `pre` element: preformatted text.
public typealias Pre = HTMLElement<HTMLTags.Pre>

extension HTMLTags {
  public enum ProgressBar: HTMLContainerTag {
    public static let name = "progress"
  }
}

/// The `progress` element: the progress of a task (the type is not called `Progress`,
/// which is a Foundation type).
public typealias ProgressBar = HTMLElement<HTMLTags.ProgressBar>

extension HTMLTags {
  public enum Q: HTMLContainerTag {
    public static let name = "q"
  }
}

/// The `q` element: an inline quotation.
public typealias Q = HTMLElement<HTMLTags.Q>

extension HTMLTags {
  public enum Rp: HTMLContainerTag {
    public static let name = "rp"
  }
}

/// The `rp` element: ruby fallback parentheses.
public typealias Rp = HTMLElement<HTMLTags.Rp>

extension HTMLTags {
  public enum Rt: HTMLContainerTag {
    public static let name = "rt"
  }
}

/// The `rt` element: a ruby annotation.
public typealias Rt = HTMLElement<HTMLTags.Rt>

extension HTMLTags {
  public enum Ruby: HTMLContainerTag {
    public static let name = "ruby"
  }
}

/// The `ruby` element: a ruby annotation.
public typealias Ruby = HTMLElement<HTMLTags.Ruby>

extension HTMLTags {
  public enum S: HTMLContainerTag {
    public static let name = "s"
  }
}

/// The `s` element: text that is no longer accurate.
public typealias S = HTMLElement<HTMLTags.S>

extension HTMLTags {
  public enum Samp: HTMLContainerTag {
    public static let name = "samp"
  }
}

/// The `samp` element: sample output.
public typealias Samp = HTMLElement<HTMLTags.Samp>

extension HTMLTags {
  public enum Search: HTMLContainerTag {
    public static let name = "search"
  }
}

/// The `search` element: a search.
public typealias Search = HTMLElement<HTMLTags.Search>

extension HTMLTags {
  public enum Section: HTMLContainerTag {
    public static let name = "section"
  }
}

/// The `section` element: a section.
public typealias Section = HTMLElement<HTMLTags.Section>

extension HTMLTags {
  public enum Select: HTMLContainerTag {
    public static let name = "select"
  }
}

/// The `select` element: a drop-down list.
public typealias Select = HTMLElement<HTMLTags.Select>

extension HTMLTags {
  public enum Slot: HTMLContainerTag {
    public static let name = "slot"
  }
}

/// The `slot` element: a slot of a web component.
public typealias Slot = HTMLElement<HTMLTags.Slot>

extension HTMLTags {
  public enum Small: HTMLContainerTag {
    public static let name = "small"
  }
}

/// The `small` element: side comments.
public typealias Small = HTMLElement<HTMLTags.Small>

extension HTMLTags {
  public enum Span: HTMLContainerTag {
    public static let name = "span"
  }
}

/// The `span` element: a generic inline container.
public typealias Span = HTMLElement<HTMLTags.Span>

extension HTMLTags {
  public enum Strong: HTMLContainerTag {
    public static let name = "strong"
  }
}

/// The `strong` element: important text.
public typealias Strong = HTMLElement<HTMLTags.Strong>

extension HTMLTags {
  public enum Sub: HTMLContainerTag {
    public static let name = "sub"
  }
}

/// The `sub` element: subscript.
public typealias Sub = HTMLElement<HTMLTags.Sub>

extension HTMLTags {
  public enum Summary: HTMLContainerTag {
    public static let name = "summary"
  }
}

/// The `summary` element: the summary of a disclosure widget.
public typealias Summary = HTMLElement<HTMLTags.Summary>

extension HTMLTags {
  public enum Sup: HTMLContainerTag {
    public static let name = "sup"
  }
}

/// The `sup` element: superscript.
public typealias Sup = HTMLElement<HTMLTags.Sup>

extension HTMLTags {
  public enum Table: HTMLContainerTag {
    public static let name = "table"
  }
}

/// The `table` element: a table.
public typealias Table = HTMLElement<HTMLTags.Table>

extension HTMLTags {
  public enum Tbody: HTMLContainerTag {
    public static let name = "tbody"
  }
}

/// The `tbody` element: the body rows of a table.
public typealias Tbody = HTMLElement<HTMLTags.Tbody>

extension HTMLTags {
  public enum Td: HTMLContainerTag {
    public static let name = "td"
  }
}

/// The `td` element: a table cell.
public typealias Td = HTMLElement<HTMLTags.Td>

extension HTMLTags {
  public enum Template: HTMLContainerTag {
    public static let name = "template"
  }
}

/// The `template` element: a template that is not rendered.
public typealias Template = HTMLElement<HTMLTags.Template>

extension HTMLTags {
  public enum Textarea: HTMLContainerTag {
    public static let name = "textarea"
  }
}

/// The `textarea` element: a multi-line text input.
public typealias Textarea = HTMLElement<HTMLTags.Textarea>

extension HTMLTags {
  public enum Tfoot: HTMLContainerTag {
    public static let name = "tfoot"
  }
}

/// The `tfoot` element: the footer rows of a table.
public typealias Tfoot = HTMLElement<HTMLTags.Tfoot>

extension HTMLTags {
  public enum Th: HTMLContainerTag {
    public static let name = "th"
  }
}

/// The `th` element: a header cell of a table.
public typealias Th = HTMLElement<HTMLTags.Th>

extension HTMLTags {
  public enum Thead: HTMLContainerTag {
    public static let name = "thead"
  }
}

/// The `thead` element: the header rows of a table.
public typealias Thead = HTMLElement<HTMLTags.Thead>

extension HTMLTags {
  public enum Time: HTMLContainerTag {
    public static let name = "time"
  }
}

/// The `time` element: a date or time.
public typealias Time = HTMLElement<HTMLTags.Time>

extension HTMLTags {
  public enum Title: HTMLContainerTag {
    public static let name = "title"
  }
}

/// The `title` element: the title of the document.
public typealias Title = HTMLElement<HTMLTags.Title>

extension HTMLTags {
  public enum Tr: HTMLContainerTag {
    public static let name = "tr"
  }
}

/// The `tr` element: a table row.
public typealias Tr = HTMLElement<HTMLTags.Tr>

extension HTMLTags {
  public enum U: HTMLContainerTag {
    public static let name = "u"
  }
}

/// The `u` element: underlined text.
public typealias U = HTMLElement<HTMLTags.U>

extension HTMLTags {
  public enum Ul: HTMLContainerTag {
    public static let name = "ul"
  }
}

/// The `ul` element: an unordered list.
public typealias Ul = HTMLElement<HTMLTags.Ul>

extension HTMLTags {
  public enum Var: HTMLContainerTag {
    public static let name = "var"
  }
}

/// The `var` element: a variable.
public typealias Var = HTMLElement<HTMLTags.Var>

extension HTMLTags {
  public enum Video: HTMLContainerTag {
    public static let name = "video"
  }
}

/// The `video` element: a video.
public typealias Video = HTMLElement<HTMLTags.Video>

// MARK: - Elements without content

extension HTMLTags {
  public enum Area: HTMLVoidTag {
    public static let name = "area"
  }
}

/// The `area` element: an area of an image map.
public typealias Area = HTMLElement<HTMLTags.Area>

extension HTMLTags {
  public enum Base: HTMLVoidTag {
    public static let name = "base"
  }
}

/// The `base` element: the base URL of the document.
public typealias Base = HTMLElement<HTMLTags.Base>

extension HTMLTags {
  public enum Br: HTMLVoidTag {
    public static let name = "br"
  }
}

/// The `br` element: a line break.
public typealias Br = HTMLElement<HTMLTags.Br>

extension HTMLTags {
  public enum Col: HTMLVoidTag {
    public static let name = "col"
  }
}

/// The `col` element: a table column.
public typealias Col = HTMLElement<HTMLTags.Col>

extension HTMLTags {
  public enum Embed: HTMLVoidTag {
    public static let name = "embed"
  }
}

/// The `embed` element: embedded content.
public typealias Embed = HTMLElement<HTMLTags.Embed>

extension HTMLTags {
  public enum Hr: HTMLVoidTag {
    public static let name = "hr"
  }
}

/// The `hr` element: a thematic break.
public typealias Hr = HTMLElement<HTMLTags.Hr>

extension HTMLTags {
  public enum Img: HTMLVoidTag {
    public static let name = "img"
  }
}

/// The `img` element: an image.
public typealias Img = HTMLElement<HTMLTags.Img>

extension HTMLTags {
  public enum Input: HTMLVoidTag {
    public static let name = "input"
  }
}

/// The `input` element: a form control.
public typealias Input = HTMLElement<HTMLTags.Input>

extension HTMLTags {
  public enum Link: HTMLVoidTag {
    public static let name = "link"
  }
}

/// The `link` element: a link to an external resource.
public typealias Link = HTMLElement<HTMLTags.Link>

extension HTMLTags {
  public enum Meta: HTMLVoidTag {
    public static let name = "meta"
  }
}

/// The `meta` element: metadata.
public typealias Meta = HTMLElement<HTMLTags.Meta>

extension HTMLTags {
  public enum Source: HTMLVoidTag {
    public static let name = "source"
  }
}

/// The `source` element: a source of a media element.
public typealias Source = HTMLElement<HTMLTags.Source>

extension HTMLTags {
  public enum Track: HTMLVoidTag {
    public static let name = "track"
  }
}

/// The `track` element: a text track of a media element.
public typealias Track = HTMLElement<HTMLTags.Track>

extension HTMLTags {
  public enum Wbr: HTMLVoidTag {
    public static let name = "wbr"
  }
}

/// The `wbr` element: a line break opportunity.
public typealias Wbr = HTMLElement<HTMLTags.Wbr>

// MARK: - Elements with code as content

extension HTMLTags {
  public enum Script: HTMLRawTextTag {
    public static let name = "script"
  }
}

/// The `script` element: a script.
public typealias Script = HTMLElement<HTMLTags.Script>

extension HTMLTags {
  public enum Style: HTMLRawTextTag {
    public static let name = "style"
  }
}

/// The `style` element: style rules.
public typealias Style = HTMLElement<HTMLTags.Style>
