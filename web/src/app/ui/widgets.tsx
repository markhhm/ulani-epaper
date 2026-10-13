/** Building blocks of the views: colour swatches, file buttons, a frame on a canvas, a modal dialog. */

import type { ComponentChildren } from 'preact';
import { useEffect, useRef } from 'preact/hooks';
import { INKS } from '../../core/cards';
import { COLOURS, type ColourName } from '../../core/palette';
import { HEIGHT, WIDTH } from '../../core/protocol';
import { type StringKey, t } from '../../i18n';
import { framePicture, indicesPicture, paint } from '../draw';

/** The seven panel colours as round buttons. */
export function Swatches(props: { label: string; value?: ColourName | undefined; onPick: (colour: ColourName) => void }) {
  return (
    <div class="swatches" role="radiogroup" aria-label={props.label}>
      {INKS.map((name) => {
        const [r, g, b] = COLOURS[name].rgb;
        return (
          <button
            type="button"
            role="radio"
            aria-checked={props.value === name}
            aria-label={t(`colour.${name}` as StringKey)}
            title={t(`colour.${name}` as StringKey)}
            class={`swatch${props.value === name ? ' on' : ''}`}
            style={{ background: `rgb(${r}, ${g}, ${b})` }}
            onClick={() => props.onPick(name)}
          />
        );
      })}
    </div>
  );
}

/** A button that opens the phone's file chooser (with `capture`, its camera) and hands over the chosen file. */
export function FileButton(props: {
  label: string;
  accept?: string;
  capture?: 'environment' | 'user';
  kind?: 'primary' | 'secondary';
  disabled?: boolean;
  onFile: (file: File) => void;
}) {
  const input = useRef<HTMLInputElement>(null);
  return (
    <>
      <button type="button" class={`btn btn-${props.kind ?? 'secondary'}`} disabled={props.disabled} onClick={() => input.current?.click()}>
        {props.label}
      </button>
      <input
        ref={input}
        type="file"
        style={{ display: 'none' }}
        {...(props.accept ? { accept: props.accept } : {})}
        {...(props.capture ? { capture: props.capture } : {})}
        onChange={(event) => {
          const target = event.currentTarget as HTMLInputElement;
          const file = target.files?.[0];
          target.value = ''; // the same file can be chosen again
          if (file) props.onFile(file);
        }}
      />
    </>
  );
}

/** A drawn frame (800 x 480 palette picture) shown at the size of the canvas element. */
export function FrameCanvas(props: { frame?: Uint8Array | undefined; indices?: Uint8Array | undefined; label?: string; small?: boolean }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const { frame, indices } = props;
  useEffect(() => {
    const element = canvas.current;
    if (!element || (!frame && !indices)) return;
    if (frame) paint(element, framePicture(frame));
    else if (indices) paint(element, indicesPicture(indices));
  }, [frame, indices]);
  const width = props.small ? 320 : WIDTH;
  const height = props.small ? 192 : HEIGHT;
  return <canvas ref={canvas} class="frame-canvas" width={width} height={height} role="img" aria-label={props.label ?? ''} />;
}

/** A modal box over the page. */
export function Dialog(props: { title: string; children: ComponentChildren }) {
  return (
    <div class="scrim">
      <div class="dialog" role="dialog" aria-modal="true" aria-label={props.title}>
        <h2>{props.title}</h2>
        {props.children}
      </div>
    </div>
  );
}
