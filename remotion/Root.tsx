import { Composition } from 'remotion'
import { TokcatLandingMotion } from './TokcatLandingMotion'

export const RemotionRoot = () => {
  return (
    <Composition
      id="TokcatLandingMotion"
      component={TokcatLandingMotion}
      durationInFrames={210}
      fps={30}
      width={1440}
      height={900}
    />
  )
}
