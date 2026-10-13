/**
 * Just enough of a DOM for Preact to render a view in Node (the tests have no browser): elements, text,
 * attributes and event handlers. A canvas draws nothing. `installDocument` puts the document in place
 * and returns the function that takes it away again.
 */

export class FakeNode {
  childNodes: FakeNode[] = [];
  parentNode: FakeNode | null = null;
  attributes: { name: string; value: string }[] = [];
  listeners: Record<string, (event: unknown) => void> = {};
  style: Record<string, unknown> = { setProperty() {} };
  readonly namespaceURI = 'http://www.w3.org/1999/xhtml';
  readonly ownerDocument = fakeDocument;

  constructor(
    readonly nodeType: 1 | 3,
    readonly localName?: string,
    public data = '',
  ) {}

  get firstChild(): FakeNode | null {
    return this.childNodes[0] ?? null;
  }
  get nextSibling(): FakeNode | null {
    const siblings = this.parentNode?.childNodes ?? [];
    return siblings[siblings.indexOf(this) + 1] ?? null;
  }
  get textContent(): string {
    return this.nodeType === 3 ? this.data : this.childNodes.map((child) => child.textContent).join('');
  }

  insertBefore(node: FakeNode, before: FakeNode | null): FakeNode {
    node.remove();
    const at = before ? this.childNodes.indexOf(before) : -1;
    if (at < 0) this.childNodes.push(node);
    else this.childNodes.splice(at, 0, node);
    node.parentNode = this;
    return node;
  }
  appendChild(node: FakeNode): FakeNode {
    return this.insertBefore(node, null);
  }
  removeChild(node: FakeNode): FakeNode {
    node.remove();
    return node;
  }
  remove(): void {
    const siblings = this.parentNode?.childNodes ?? [];
    if (siblings.includes(this)) siblings.splice(siblings.indexOf(this), 1);
    this.parentNode = null;
  }
  setAttribute(name: string, value: unknown): void {
    this.removeAttribute(name);
    this.attributes.push({ name, value: String(value) });
  }
  removeAttribute(name: string): void {
    this.attributes = this.attributes.filter((attribute) => attribute.name !== name);
  }
  getAttribute(name: string): string | null {
    return this.attributes.find((attribute) => attribute.name === name)?.value ?? null;
  }
  addEventListener(name: string, listener: (event: unknown) => void): void {
    this.listeners[name] = listener;
  }
  removeEventListener(name: string): void {
    delete this.listeners[name];
  }
  getContext(): null {
    return null;
  }

  /** This node and everything in it, in document order. */
  all(): FakeNode[] {
    return [this, ...this.childNodes.flatMap((child) => child.all())];
  }
  /** Tap this element: run its click handler. */
  click(): void {
    this.listeners.click?.call(this, { type: 'click' });
  }
}

const fakeDocument = {
  createElement: (name: string) => new FakeNode(1, name),
  createElementNS: (_namespace: string, name: string) => new FakeNode(1, name),
  createTextNode: (text: unknown) => new FakeNode(3, undefined, String(text)),
};

/** Make `document` the fake one; returns the function that puts back what was there. */
export function installDocument(): () => void {
  const scope = globalThis as { document?: unknown };
  const before = scope.document;
  scope.document = fakeDocument;
  return () => {
    scope.document = before;
  };
}
