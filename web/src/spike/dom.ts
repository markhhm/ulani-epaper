/**
 * Minimal DOM helpers for the diagnostics page (no framework: the page is
 * small and should run in any browser that has Web Bluetooth).
 */

export type Child = Node | string | number | null | undefined | false | readonly Child[];

type Handler = (event: Event) => void;

/** Attributes (set as given; `true` sets an empty attribute) and `on<event>` handlers. */
export type Props = Readonly<Record<string, string | number | boolean | Handler | null | undefined>>;

/** `document.createElement(tag)` with attributes, handlers and children. */
export function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props?: Props | null,
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const element = document.createElement(tag);
  for (const [key, value] of Object.entries(props ?? {})) {
    if (value === undefined || value === null || value === false) continue;
    if (typeof value === 'function') {
      element.addEventListener(key.slice(2).toLowerCase(), value);
    } else {
      element.setAttribute(key, value === true ? '' : String(value));
    }
  }
  append(element, children);
  return element;
}

/** Append children; strings and numbers become text, arrays are flattened, empty values skipped. */
export function append(parent: Node, children: readonly Child[]): void {
  for (const child of children) {
    if (child === null || child === undefined || child === false) continue;
    if (Array.isArray(child)) append(parent, child);
    else if (typeof child === 'string' || typeof child === 'number') parent.appendChild(document.createTextNode(String(child)));
    else parent.appendChild(child as Node);
  }
}

/** Replace all children of `parent`. */
export function setChildren(parent: Element, ...children: Child[]): void {
  while (parent.firstChild) parent.removeChild(parent.firstChild);
  append(parent, children);
}
